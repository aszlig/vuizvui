{ config, lib, pkgs, ... }:

let
  cfg = config.humblebundle;

  self = rec {
    callPackage = pkgs.lib.callPackageWith (pkgs // self);
    callPackage_i686 = pkgs.lib.callPackageWith (pkgs.pkgsi686Linux // self);

    fetchHumbleBundle = callPackage ./fetch-humble-bundle {
      inherit (config.humblebundle) email password;
    };

    antichamber = callPackage_i686 ./antichamber.nix { };
    baba-is-you = callPackage ./baba-is-you.nix { };
    bastion = callPackage ./bastion.nix {};
    brigador = callPackage ./brigador.nix {};
    cavestoryplus = callPackage ./cavestoryplus.nix {};
    dott = callPackage_i686 ./dott.nix {};
    fez = callPackage ./fez.nix {};
    ftl = callPackage ./ftl.nix {};
    guacamelee = callPackage_i686 ./guacamelee.nix {};
    grim-fandango = callPackage_i686 ./grim-fandango.nix {};
    hammerwatch = callPackage ./hammerwatch.nix {};
    jamestown = callPackage ./jamestown.nix {};
    liads = callPackage ./liads.nix {};
    megabytepunch = callPackage_i686 ./megabytepunch.nix {};
    minimetro = callPackage ./minimetro.nix {};
    opus-magnum = callPackage ./opus-magnum.nix {};
    owlboy = callPackage ./owlboy.nix {};
    pico-8 = callPackage ./pico-8.nix {};
    rocketbirds = callPackage ./rocketbirds.nix {};
    spacechem = callPackage_i686 ./spacechem.nix {};
    spaz = callPackage ./spaz.nix {};
    starbound = callPackage ./starbound.nix {};
    swordsandsoldiers = callPackage ./swordsandsoldiers.nix {};
    the-bridge = callPackage_i686 ./the-bridge.nix {};
    trine2 = callPackage_i686 ./trine2.nix {};
    unepic = callPackage ./unepic.nix {};
  };
in with lib; {
  options.humblebundle = {
    email = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Email address for your HumbleBundle account.
      '';
    };

    password = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Password for your HumbleBundle account.
      '';
    };
  };

  config.packages = {
    humblebundle = mkIf (cfg.email != null && cfg.password != null) self;
  };
}
