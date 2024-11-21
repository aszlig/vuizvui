{ buildGame, fetchHumbleBundle, lib

, SDL, SDL_gfx, SDL_image, SDL_mixer, SDL_net, SDL_ttf
, coreutils, makeWrapper, mono4, smpeg, sqlite, xclip
}:

with lib;

buildGame rec {
  version = "1013_FIXED";
  name = "spacechem-${version}";
  src = fetchHumbleBundle {
    name = "SpaceChem_Linux_v1013_FIXED.zip";
    machineName = "spacechem_android_pc_soundtrack_linux";
    downloadName = "Download";
    md5 = "c290e8631ae3380b7e70362501a5adb6";
  };

  sandbox.paths.required = [
    "$XDG_DATA_HOME/Zachtronics Industries/SpaceChem"
  ];

  nativeBuildInputs = [ makeWrapper ];

  postPatch = let
    dllmap = {
      SDL = "${SDL}/lib/libSDL.so";
      SDL_image = "${SDL_image}/lib/libSDL_image.so";
      SDL_mixer = "${SDL_mixer}/lib/libSDL_mixer.so";
      SDL_ttf = "${SDL_ttf}/lib/libSDL_ttf.so";
      SDL_net = "${SDL_net}/lib/libSDL_net.so";
      smpeg = "${smpeg}/lib/libsmpeg.so";
      SDL_gfx = "${SDL_gfx}/lib/libSDL_gfx.so";
    };
  in ''
    ${concatStrings (mapAttrsToList (dll: target: ''
      sed -i -e '/<dllmap dll="${dll}\.dll">/,/<\/dllmap>/ {
        /dllentry os="linux"/s!dll="[^"]*"!dll="'"${target}"'"!
      }' SpaceChem/Tao.Sdl.dll.config
    '') dllmap)}

    rm SpaceChem/Mono.Security.dll
    rm SpaceChem/spacechem-launcher.sh

    cat > SpaceChem/System.Data.SQLite.dll.config <<EOF
    <configuration>
      <dllmap dll="sqlite3" target="${sqlite.out}/lib/libsqlite3.so" os="linux"/>
    </configuration>
    EOF
    cat > SpaceChem/SpaceChem.exe.config <<EOF
    <configuration>
      <startup><supportedRuntime version="v4.0"/></startup></configuration>
      <dllmap dll="sqlite3" target="${sqlite.out}/lib/libsqlite3.so" os="linux"/>
    </configuration>
    EOF
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib
    cp -rvt $out/lib SpaceChem

    runHook postInstall
  '';

  # coreutils because Tao.OpenGL relies on uname for platform detection
  # xclip because SpaceChem relies on it for import/export of challenges
  postInstall = ''
    makeWrapper ${mono4}/bin/mono $out/bin/spacechem \
      --prefix PATH : ${coreutils}/bin               \
      --prefix PATH : ${xclip}/bin                   \
      --run "cd $out/lib/SpaceChem"                  \
      --add-flags $out/lib/SpaceChem/SpaceChem.exe
  '';
}
