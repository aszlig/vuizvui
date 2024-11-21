{ config, lib, pkgs, ... }:

let
  cfg = config.foss;

  self = rec {
    callPackage = pkgs.lib.callPackageWith (pkgs // self);
    callPackage_i686 = pkgs.lib.callPackageWith (pkgs.pkgsi686Linux // self);

    ultrastar-play = callPackage ./ultrastar-play.nix {};
  };
in {
  options.foss = {
  };

  config.packages = {
    foss = self;
  };
}
