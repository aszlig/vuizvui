
{ lib, stdenv, fetchurl
, buildUnity
, autoreconfHook
, unzip
, buildFHSEnv
, writeScript
, fetchFromGitHub
, autoPatchelfHook
, fetchpatch
, pkg-config
, lua
, fpc
, pcre
, portaudio
, freetype
, libpng
, SDL2
, SDL2_image
, SDL2_gfx
, SDL2_mixer
, SDL2_net, SDL2_ttf
, ffmpeg_4
, sqlite
, zlib
, libGLU
, libGL
, xorg
}:

let
  sharedLibs = [
    pcre portaudio freetype
    # SDL2 SDL2_image SDL2_gfx SDL2_mixer SDL2_net SDL2_ttf
    sqlite lua zlib xorg.libX11 libGLU libGL ffmpeg_4
  ];

  unpacked = buildUnity {
    name = "ultrastar-play";
    version = "0.9.0";
    fullName = "UltraStar Play";

    # src = fetchFromGitHub {
    #   owner = "UltraStar-Deluxe";
    #   repo = "Play";
    #   rev = "v${version}";
    #   hash = "sha256-KvYf4dpgN72F8Y5iFNba0SCjPoS33O3FAdrrC49xoGo=";
    # };
    src = fetchurl {
      url = "https://github.com/UltraStar-Deluxe/Play/releases/download/v0.9.0/UltraStarPlay-v0.9.0-Linux64.zip";
      sha256 = "sha256-kC4jb2KSOyDrAweHzlyWO1tB7D0/wGPXXP+SXF1Rz6k=";
    };

    # phases = [ "installPhase" "fixupPhase" ];

    nativeBuildInputs = [ pkg-config unzip autoPatchelfHook ];
    buildInputs = [ libpng ] ++ sharedLibs;

    # postPatch = ''
    # '';

    preInstall = ''
      mv 'UltraStar Play' 'UltraStar Play.x86_64'

      mkdir -p $out/share/lib
      cp -a UnityPlayer.so $out/share/lib
    '';

  };

in unpacked
# in buildFHSEnv {
#   # inherit (unpacked) pname version;

#   name = "ultrastar-play";

#   runScript = writeScript "run-ultrastar-play" ''
#     set -iuo pipefail
#     tmp=$(mktemp -d ultrastar-play-XXXXX)

#     clean_up() {
#         rm -rf "$tmp"
#     }
#     trap clean_up EXIT SIGINT SIGTERM

#     cd "$tmp"
#     cp -a --reflink=auto ${unpacked}/ "$tmp"

#     chmod --recursive +w "$tmp"

#     "$tmp/UltraStar Play";
#   '';


#   meta = with lib; {
#     homepage = "https://ultrastar-play.com";
#     description = "Free and open source singing game with song editor for desktop, mobile, and smart TV ";
#     license = licenses.mit;
#     maintainers = with maintainers; [ Profpatsch ];
#   };
# }
