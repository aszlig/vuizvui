#define _GNU_SOURCE

#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <sched.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "params.h"
#include "path-cache.h"
#ifndef FULL_NIX_STORE
#include "nix-query.h"
#endif

static path_cache cached_paths = NULL;

static bool write_proc(int proc_pid_fd, const char *fname, const char *buf,
                       size_t buflen, bool ignore_errors)
{
    int fd;

    if ((fd = openat(proc_pid_fd, fname, O_WRONLY)) == -1) {
        fprintf(stderr, "open %s: %s\n", fname, strerror(errno));
        return false;
    }

    if (write(fd, buf, buflen) == -1) {
        if (!ignore_errors)
            fprintf(stderr, "write %s: %s\n", fname, strerror(errno));
        close(fd);
        return ignore_errors;
    }

    close(fd);
    return true;
}

#define WRITE_IDMAP(file, value) \
    buflen = snprintf(buf, 100, "%1$lu %1$lu 1", (unsigned long)value); \
    if (buflen >= 100) { \
        fputs("Unable to write buffer for " file ".\n", stderr); \
        close(proc_pid_fd); \
        return false; \
    } else if (buflen < 0) { \
        perror("snprintf " file " buffer"); \
        close(proc_pid_fd); \
        return false; \
    } \
    if (!write_proc(proc_pid_fd, file, buf, buflen, false)) { \
        close(proc_pid_fd); \
        return false; \
    }

bool write_maps(pid_t parent_pid)
{
    int proc_pid_fd;
    size_t buflen;
    char buf[100];

    buflen = snprintf(buf, 100, "/proc/%lu", (unsigned long)parent_pid);
    if (buflen >= 100) {
        fputs("Unable to write buffer for child pid proc path.\n", stderr);
        return false;
    } else if (buflen < 0) {
        perror("snprintf child pid proc path");
        return false;
    }

    if ((proc_pid_fd = open(buf, O_RDONLY | O_DIRECTORY)) == -1) {
        fprintf(stderr, "open %s: %s\n", buf, strerror(errno));
        return false;
    }

    WRITE_IDMAP("uid_map", geteuid());

    // Kernels prior to Linux 3.19 which do not impose setgroups()
    // restrictions won't have this file, so ignore failure.
    write_proc(proc_pid_fd, "setgroups", "deny", 4, true);

    WRITE_IDMAP("gid_map", getegid());

    return true;
}

static bool makedirs(const char *path, bool do_cache)
{
    char *tmp, *segment;

    if (*path != '/') {
        fprintf(stderr, "fatal: Path '%s' is not absolute.\n", path);
        return false;
    }

    if ((tmp = strdup(path)) == NULL) {
        fprintf(stderr, "strdup of %s: %s\n", path, strerror(errno));
        return false;
    }

    segment = dirname(tmp);

    if (!(segment[0] == '/' && segment[1] == '\0')) {
        if (!makedirs(segment, do_cache)) {
            free(tmp);
            return false;
        }
    }

    if (!do_cache || cache_path(cached_paths, path))
        (void)mkdir(path, 0755);
    free(tmp);
    return true;
}

char *get_mount_target(const char *path)
{
    size_t pathlen = strlen(path), rootdir_len = strlen(FS_ROOT_DIR);
    char *target;

    if ((target = malloc(rootdir_len + pathlen + 1)) == NULL) {
        perror("malloc mount target");
        return NULL;
    }

    memcpy(target, FS_ROOT_DIR, rootdir_len);
    memcpy(target + rootdir_len, path, pathlen + 1);
    return target;
}

static bool is_regular_file(const char *path)
{
    struct stat st;
    stat(path, &st);
    return S_ISREG(st.st_mode);
}

static bool bind_file(const char *path)
{
    char *target, *tmp;

    if (access(path, R_OK) == -1)
        // Skip missing mount source
        return true;

    if ((target = get_mount_target(path)) == NULL)
        return false;

    if ((tmp = strdup(target)) == NULL) {
        perror("strdup bind file target path");
        free(target);
        return false;
    }

    if (!makedirs(dirname(tmp), true)) {
        free(target);
        free(tmp);
        return false;
    }

    free(tmp);

    if (!cache_path(cached_paths, path)) {
        free(target);
        return true;
    }

    if (creat(target, 0666) == -1) {
        fprintf(stderr, "unable to create %s: %s\n", target, strerror(errno));
        free(target);
        return false;
    }

    if (mount(path, target, "", MS_BIND, NULL) == -1) {
        fprintf(stderr, "mount file %s to %s: %s\n",
                path, target, strerror(errno));
        free(target);
        return false;
    }

    free(target);
    return true;
}

static bool makelinks(const char *from, const char *to)
{
    char linktarget[PATH_MAX];
    char *target, *tmp;
    ssize_t linksize;
    bool result;

    if (strcmp(from, to) == 0)
        return true;

    if ((linksize = readlink(from, linktarget, PATH_MAX)) == -1) {
        if (errno == EINVAL)
            // Not a symbolic link
            return true;

        fprintf(stderr, "reading link %s: %s\n", from, strerror(errno));
        return false;
    }

    linktarget[linksize] = '\0';

    if ((target = get_mount_target(from)) == NULL)
        return false;

    if ((tmp = strdup(target)) == NULL) {
        fprintf(stderr, "strdup of %s: %s\n", target, strerror(errno));
        free(target);
        return false;
    }

    if (!makedirs(dirname(tmp), true)) {
        free(target);
        free(tmp);
        return false;
    }

    free(tmp);

    if (cache_path(cached_paths, target)) {
        if (symlink(linktarget, target) == -1) {
            if (errno == EEXIST)
                goto recurse;

            fprintf(stderr, "creating symlink from %s to %s: %s\n",
                    target, linktarget, strerror(errno));
            free(target);
            return false;
        }
    }

recurse:
    result = makelinks(linktarget, to);
    free(target);
    return result;
}

bool bind_mount(const char *path, bool rdonly, bool restricted, bool resolve)
{
    int base_mflags = MS_BIND | MS_REC, mflags = 0;
    const char *msrc;
    char src[PATH_MAX], *target;

    if (rdonly)
        mflags |= MS_RDONLY;

    if (restricted)
        mflags |= MS_NOSUID | MS_NODEV;

    if (resolve ? realpath(path, src) == NULL : access(path, F_OK) == -1)
        // Skip missing mount source
        return true;

    msrc = resolve ? src : path;

    if (is_regular_file(msrc))
        return bind_file(msrc);

    if ((target = get_mount_target(msrc)) == NULL)
        return false;

    if (resolve) {
        if (!makelinks(path, src)) {
            free(target);
            return false;
        }
    }

    if (!makedirs(target, false)) {
        free(target);
        return false;
    }

    if (!cache_path(cached_paths, msrc)) {
        free(target);
        return true;
    }

    if (mount(msrc, target, "", base_mflags, NULL) == -1) {
        fprintf(stderr, "mount %s to %s: %s\n", msrc, target, strerror(errno));
        free(target);
        return false;
    }

    if (mflags != 0) {
        mflags |= base_mflags | MS_REMOUNT;
        if (mount("none", target, "", mflags, NULL) == -1) {
            fprintf(stderr, "remount %s: %s\n", target, strerror(errno));
            free(target);
            return false;
        }
    }

    free(target);
    return true;
}

struct envar_offset {
    int start;
    int length;
    int var_start;
    int var_length;
    struct envar_offset *next;
};

static struct envar_offset *alloc_offset(void)
{
    struct envar_offset *new_offset;
    new_offset = malloc(sizeof(struct envar_offset));

    if (new_offset == NULL) {
        perror("malloc envar_offset");
        return NULL;
    }

    new_offset->next = NULL;
    return new_offset;
}

static struct envar_offset *push_offset(struct envar_offset *current,
                                        struct envar_offset **base)
{
    if (current == NULL) {
        if ((current = alloc_offset()) != NULL)
            *base = current;
        return current;
    }

    return current->next = alloc_offset();
}

static void free_offsets(struct envar_offset *base)
{
    struct envar_offset *next;
    if (base == NULL)
        return;
    next = base->next;
    free(base);
    if (next != NULL)
        free_offsets(next);
}

#define MK_XDG_EXPAND(varname, fallback) \
    if (strcmp(xdg_var, varname) == 0) { \
        result = malloc(homelen + sizeof fallback); \
        if (result == NULL) { \
            perror("malloc " varname); \
            return NULL; \
        } \
        memcpy(result, home, homelen); \
        memcpy(result + homelen, fallback, sizeof fallback); \
        return result; \
    }

static char *expand_xdg_fallback(const char *xdg_var)
{
    static char *home = NULL;
    static size_t homelen;
    char *result;

    if (home == NULL) {
        if ((home = getenv("HOME")) == NULL) {
            fputs("Unable find $HOME.\n", stderr);
            return NULL;
        }
        homelen = strlen(home);
    }

    MK_XDG_EXPAND("XDG_DATA_HOME", "/.local/share");
    MK_XDG_EXPAND("XDG_CONFIG_HOME", "/.config");
    MK_XDG_EXPAND("XDG_CACHE_HOME", "/.cache");

    return NULL;
}

static char *get_offset_var(struct envar_offset *offset, const char *haystack)
{
    char *tmp, *result;

    tmp = strndup(haystack + offset->var_start, offset->var_length);

    if (tmp == NULL) {
        perror("strndup");
        return NULL;
    }

    result = getenv(tmp);
    if (result == NULL) {
        if ((result = expand_xdg_fallback(tmp)) == NULL) {
            fprintf(stderr, "Unable find variable %s in %s\n", tmp, haystack);
            free(tmp);
            return NULL;
        }
        free(tmp);
        return result;
    }
    free(tmp);
    return strdup(result);
}

static char *replace_env_offset_free(const char *path,
                                     struct envar_offset *offset)
{
    struct envar_offset *tmp_offset;
    size_t buflen, pathlen, varlen, tmplen;
    int inpos = 0, outpos = 0;
    char *buf, *curvar;

    buflen = pathlen = strlen(path);

    if ((buf = malloc(buflen + 1)) == NULL) {
        perror("malloc replace_env buffer");
        return NULL;
    }

    while (offset != NULL) {
        if ((curvar = get_offset_var(offset, path)) == NULL) {
            free(buf);
            free_offsets(offset);
            return NULL;
        }

        varlen = strlen(curvar);
        tmplen = varlen + (buflen - offset->length);

        if (tmplen > buflen) {
            if ((buf = realloc(buf, (buflen = tmplen) + 1)) == NULL) {
                perror("realloc replace_env buffer");
                free(buf);
                free(curvar);
                free_offsets(offset);
                return NULL;
            }
        }

        memcpy(buf + outpos, path + inpos, offset->start - inpos);
        outpos += offset->start - inpos;
        inpos = offset->start;

        memcpy(buf + outpos, curvar, varlen);
        outpos += varlen;
        inpos += offset->length;

        free(curvar);

        tmp_offset = offset;
        offset = offset->next;
        free(tmp_offset);
    }

    memcpy(buf + outpos, path + inpos, pathlen - inpos);
    *(buf + outpos + (pathlen - inpos)) = '\0';

    return buf;
}

static char *replace_env(const char *path)
{
    int i = 0, start = 0, var_start = 0;
    size_t pathlen;
    bool in_var = false, curly = false;
    struct envar_offset *base = NULL, *offset = NULL;

    pathlen = strlen(path);

    while (i < pathlen) {
        if (path[i] == '$' && !curly && !in_var) {
            if (i + 1 >= pathlen)
                break;

            start = i;

            if (path[i + 1] == '{') {
                curly = true;
                var_start = i + 2;
                ++i;
            } else {
                in_var = true;
                var_start = i + 1;
            }
        } else if (in_var) {
            if (!(path[i] >= 'a' && path[i] <= 'z') &&
                !(path[i] >= 'A' && path[i] <= 'Z') &&
                !(path[i] >= '0' && path[i] <= '9') &&
                path[i] != '_'
            ) {
                in_var = false;

                if ((offset = push_offset(offset, &base)) == NULL) {
                    free_offsets(base);
                    return NULL;
                }

                offset->start = start;
                offset->length = i - start;
                offset->var_start = var_start;
                offset->var_length = i - var_start;
                continue;
            }
        } else if (curly) {
            if (path[i] == '}') {
                curly = false;

                if ((offset = push_offset(offset, &base)) == NULL) {
                    free_offsets(base);
                    return NULL;
                }

                offset->start = start;
                offset->length = (i + 1) - offset->start;
                offset->var_start = var_start;
                offset->var_length = i - offset->var_start;
            }
        }

        ++i;
    }

    if (in_var) {
        if ((offset = push_offset(offset, &base)) == NULL) {
            free_offsets(base);
            return NULL;
        }

        offset->start = start;
        offset->length = i - start;
        offset->var_start = var_start;
        offset->var_length = i - var_start;
    }

    return replace_env_offset_free(path, base);
}

bool extra_mount(const char *path, bool is_required)
{
    char *expanded;

    if ((expanded = replace_env(path)) == NULL)
        return false;

    if (is_required && !makedirs(expanded, false))
        return false;

    if (!bind_mount(expanded, false, true, true)) {
        free(expanded);
        return false;
    }

    free(expanded);
    return true;
}

static bool setup_xauthority(void)
{
    char *xauth, *home;
    bool result;
    size_t homelen;

    if ((xauth = getenv("XAUTHORITY")) != NULL)
        return bind_file(xauth);

    if ((home = getenv("HOME")) == NULL) {
        fputs("Unable find $HOME.\n", stderr);
        return false;
    }

    homelen = strlen(home);

    if ((xauth = malloc(homelen + 13)) == NULL) {
        perror("malloc xauth file path");
        return false;
    }

    memcpy(xauth, home, homelen);
    memcpy(xauth + homelen, "/.Xauthority", 13);

    result = bind_file(xauth);
    free(xauth);
    return result;
}

#ifdef BINSH_EXECUTABLE
static bool setup_binsh(const char *executable)
{
    if (!makedirs(FS_ROOT_DIR "/bin", false))
        return false;

    if (symlink(executable, FS_ROOT_DIR "/bin/sh") == -1) {
        fprintf(stderr, "creating symlink from %s to %s: %s\n",
                executable, FS_ROOT_DIR "/bin/sh", strerror(errno));
        return false;
    }
    return true;
}
#endif

#ifndef FULL_NIX_STORE
static bool is_dir(const char *path)
{
    struct stat sb;
    if (stat(path, &sb) == -1) {
        fprintf(stderr, "stat %s: %s\n", path, strerror(errno));
        // Default to directory for mounting
        return true;
    }
    return S_ISDIR(sb.st_mode);
}

static bool mount_requisites(struct query_state *qs, const char *path)
{
    const char *requisite;

    if (!query_requisites(qs, path)) {
        fprintf(stderr, "Unable to get requisites for %s.\n", path);
        return false;
    }

    while ((requisite = next_query_result(qs)) != NULL) {
        if (is_dir(requisite)) {
            if (!bind_mount(requisite, true, true, false))
                return false;
        } else {
            if (!bind_file(requisite))
                return false;
        }
    }

    return true;
}

bool mount_from_path_var(struct query_state *qs, const char *name)
{
    char *buf, *ptr, *value = getenv(name);

    if (value == NULL)
        return true;

    if ((buf = strdup(value)) == NULL) {
        fprintf(stderr, "strdup %s: %s\n", value, strerror(errno));
        return false;
    }

    ptr = strtok(buf, ":");

    while (ptr != NULL) {
        if (!mount_requisites(qs, ptr)) {
            free(buf);
            return false;
        }
        ptr = strtok(NULL, ":");
    }

    free(buf);
    return true;
}

/* `/etc/static` is a special symlink on NixOS, pointing to a storepath
   of configs that have to be available at runtime for some programs
   to function. So we need to mount the closure of that storepath. */
static bool setup_static_etc(struct query_state *qs)
{
    char dest[PATH_MAX];
    ssize_t destlen;

    if ((destlen = readlink("/etc/static", dest, PATH_MAX)) == -1)
        return true;

    if (destlen >= PATH_MAX) {
        fputs("readlink of /etc/static larger than PATH_MAX.\n", stderr);
        return false;
    }

    dest[destlen] = '\0';
    return mount_requisites(qs, dest);
}

/* Bind-mount all necessary nix store paths. */
static bool setup_runtime_paths(void)
{
    struct query_state *qs;

    if ((qs = new_query()) == NULL) {
        fputs("Unable to allocate Nix query state.\n", stderr);
        return false;
    }

    if (!setup_static_etc(qs)) {
        free_query(qs);
        return false;
    }

    if (!mount_runtime_path_vars(qs)) {
        free_query(qs);
        return false;
    }

    free_query(qs);
    return true;
}
#endif

static bool setup_runtime_debug(void)
{
    char *injected_files, *buf, *ptr, *equals, *target;

    if ((injected_files = getenv("NIX_SANDBOX_DEBUG_INJECT_DIRS")) == NULL)
        return true;

    if ((buf = strdup(injected_files)) == NULL) {
        perror("strdup NIX_SANDBOX_DEBUG_INJECT_DIRS");
        return false;
    }

    ptr = strtok(buf, ":");

    while (ptr != NULL) {
        if ((equals = strchr(ptr, '=')) != NULL) {
            *equals = '\0';

            if ((target = get_mount_target(equals + 1)) == NULL) {
                free(buf);
                return false;
            }

            if (!makedirs(target, true)) {
                free(target);
                free(buf);
                return false;
            }

            if (mount(ptr, target, "", MS_BIND, NULL) == -1) {
                fprintf(stderr, "mount injected directory %s to %s: %s\n",
                        ptr, target, strerror(errno));
                free(target);
                free(buf);
                return false;
            }

            free(target);
            fprintf(stderr, "Injected directory '%s' to '%s'.\n",
                    ptr, equals + 1);
        }

        ptr = strtok(NULL, ":");
    }

    free(buf);
    return true;
}

static bool setup_chroot(void)
{
    int mflags;

    mflags = MS_NOEXEC | MS_NOSUID | MS_NODEV | MS_NOATIME;

    if (mount("none", FS_ROOT_DIR, "tmpfs", mflags, NULL) == -1) {
        perror("mount rootfs");
        return false;
    }

    if (!bind_mount("/etc", true, true, false))
        return false;

    if (!bind_mount("/dev", false, false, false))
        return false;

#if (EXTRA_NS_FLAGS) & CLONE_NEWPID
        if (!makedirs(FS_ROOT_DIR "/proc", false))
            return false;

        if (mount("none", FS_ROOT_DIR "/proc", "proc", 0, NULL) == -1) {
            perror("mount /proc");
            return false;
        }
#else
        if (!bind_mount("/proc", false, false, false))
            return false;
#endif

    if (!bind_mount("/sys", false, false, false))
        return false;

    if (!bind_mount("/run", false, false, false))
        return false;

    if (!bind_mount("/var/run", false, false, false))
        return false;

    if (!bind_mount("/tmp", false, true, false))
        return false;

    // We don’t need to query the nix store if we mount the full store
#ifndef FULL_NIX_STORE
    if (!setup_runtime_paths())
        return false;
#endif

    if (!setup_app_paths())
        return false;

    if (!setup_xauthority())
        return false;

    if (!setup_runtime_debug())
        return false;

#ifdef BINSH_EXECUTABLE
    if (!setup_binsh(BINSH_EXECUTABLE))
        return false;
#endif

    if (chroot(FS_ROOT_DIR) == -1) {
        perror("chroot");
        return false;
    }

    if (chdir("/") == -1) {
        perror("chdir rootfs");
        return false;
    }

    return true;
}

bool setup_sandbox(void)
{
    int sync_pipe[2];
    char sync_status = '.';
    int child_status;
    pid_t pid, parent_pid;

    if (pipe(sync_pipe) == -1) {
        perror("pipe");
        return false;
    }

    parent_pid = getpid();

    switch (pid = fork()) {
        case -1:
            perror("fork");
            return false;
        case 0:
            close(sync_pipe[1]);
            if (read(sync_pipe[0], &sync_status, 1) == -1) {
                perror("read pipe from parent");
                _exit(1);
            } else if (sync_status == 'X')
                _exit(1);
            close(sync_pipe[0]);
            _exit(write_maps(parent_pid) ? 0 : 1);
        default:
            if (unshare(CLONE_NEWNS | CLONE_NEWUSER | EXTRA_NS_FLAGS) == -1) {
                perror("unshare");
                if (write(sync_pipe[1], "X", 1) == -1)
                    perror("signal child exit");
                waitpid(pid, NULL, 0);
                return false;
            }

            close(sync_pipe[1]);
            waitpid(pid, &child_status, 0);
            if (WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0)
                break;
            return false;
    }

    if ((pid = fork()) == -1) {
        perror("fork PID namespace");
        return false;
    }

    /* Just wait in the parent until the child exits. We need to fork because
     * otherwise we can't mount /proc in the right PID namespace.
     */
    int wstatus;
    if (pid > 0) {

        if (waitpid(pid, &wstatus, 0) == -1) {
          fputs("sandbox: waitpid failure", stderr);
          _exit(EXIT_FAILURE);
        }
        else if (WIFEXITED(wstatus)) {
          _exit(WEXITSTATUS(wstatus));
        }
        else if (WIFSIGNALED(wstatus)) {
          fprintf(stderr, "sandbox: killed by signal %d\n", WTERMSIG(wstatus));
          _exit(EXIT_FAILURE);
        }
        else {
          // WIFSTOPPED, WIFCONTINUED?
          fputs("sandbox: wait failed", stderr);
          _exit(EXIT_FAILURE);
        }
    }

    cached_paths = new_path_cache();

    if (!setup_chroot()) {
        free_path_cache(cached_paths);
        return false;
    }

    free_path_cache(cached_paths);
    return true;
}
