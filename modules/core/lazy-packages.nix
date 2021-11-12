{ config, pkgs, lib, ... }:

let
  inherit (lib) escapeShellArg;
  inherit (config.vuizvui) lazyPackages;

  # Encode the store path in base 64 so that the wrapper
  # doesn't have a direct dependency on the package.
  encoder = "${escapeShellArg "${pkgs.coreutils}/bin/base64"} -w0";
  decoder = "${escapeShellArg "${pkgs.coreutils}/bin/base64"} -d";

  # The command used to fetch the store path from the binary cache.
  fetchSubstitute = "${escapeShellArg "${pkgs.nix}/bin/nix-store"} -r";

  mkWrapper = {package, extraErrorMessage ? ""}: pkgs.runCommandLocal "${package.name}-lazy" {
    inherit package;
    inherit extraErrorMessage;
  } ''
    encoded="$(echo "$package" | ${encoder})"

    if [ ! -e "$package/bin" ]; then
      echo "Store path $package doesn't have a \`bin' directory" \
           "so we can't create lazy wrappers for it." \
           "$extraErrorMessage" >&2
      exit 1
    fi

    for bin in "$package"/bin/*; do
      [ -x "$bin" -a ! -d "$bin" ] || continue
      binpath="''${bin#$package/}"

      mkdir -p "$out/bin"
      ( echo ${escapeShellArg "#!${pkgs.stdenv.shell}"}
        echo "encoded='$encoded'"
        echo "binpath='$binpath'"
        echo -n ${escapeShellArg ''
          storepath="$(echo "$encoded" | ${decoder})"
          program="$storepath/$binpath"
          if [ ! -e "$storepath" ]; then
            ${fetchSubstitute} "$storepath" > /dev/null || exit $?
          fi
          exec "$program" "$@"
        ''}
      ) > "$out/bin/$(basename "$bin")"
      chmod +x "$out/bin/$(basename "$bin")"
    done
  '';

  vuizvuiWrapper = package: mkWrapper {
    inherit package;
    extraErrorMessage = "Please remove `${escapeShellArg package.name}' from `vuizvui.lazyPackages'.";
  };

  wrappers = map vuizvuiWrapper config.vuizvui.lazyPackages;

in {
  options.vuizvui.lazyPackages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [];
    example = lib.literalExample "[ pkgs.gimp pkgs.libreoffice ]";
    description = ''
      Packages which are built for this system but instead of being a full
      runtime dependency, only wrappers of all executables that reside in the
      <literal>bin</literal> directory are actually runtime dependencies.

      As soon as one of these wrappers is executed, the real package is fetched
      and the corresponding binary is executed.
    '';
  };

  config.environment.systemPackages = map vuizvuiWrapper lazyPackages;
}
