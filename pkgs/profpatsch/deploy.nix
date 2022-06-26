# The only deployment tool that anybody should take seriously
{ pkgs, getBins }:

let
  bins = getBins pkgs.coreutils [ "realpath" ]
      // getBins pkgs.openssh [ "ssh" ]
      // getBins pkgs.nix [ "nix-build" "nix-copy-closure" ]
      ;

  deploy = pkgs.writers.writeDash "deploy-machine-profpatsch" ''
    set -e
    MACHINE="''${1?please set machine as first argument}"
    HOME="''${HOME?please make sure HOME is set}"
    VUIZVUI="$HOME/vuizvui"
    OUT_LINK="$VUIZVUI/machines/profpatsch/system-$MACHINE"

    ${bins.nix-build} \
      --show-trace \
      --out-link "$OUT_LINK" \
      -I "nixpkgs=$HOME/nixpkgs" \
      -A "machines.profpatsch.$MACHINE.build" \
      "$VUIZVUI"

    ${bins.nix-copy-closure} \
      --to "$MACHINE?compress=true" \
      --use-substitutes \
      "$OUT_LINK"


    ${bins.ssh} \
      "root@$MACHINE" \
      "$(${bins.realpath} $OUT_LINK)/bin/switch-to-configuration" \
      "switch"
  '';

in {
  inherit
    deploy
    ;
}
