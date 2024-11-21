{ config ? null, pkgs ? import <nixpkgs> {}
, pkgsi686Linux ? pkgs.pkgsi686Linux
}:

let
  configFilePath = let
    xdgConfig = builtins.getEnv "XDG_CONFIG_HOME";
    fallback = "${builtins.getEnv "HOME"}/.config";
    basedir = if xdgConfig == "" then fallback else xdgConfig;
  in "${basedir}/nixgames.nix";

  configFile = if !builtins.pathExists configFilePath then throw ''
    The config file "${configFilePath}" doesn't exist! Be sure to create it and
    put your credentials in it, for example to use HumbleBundle games:

    {
      humblebundle.email = "fancyuser@example.com";
      humblebundle.password = "my_super_secret_password";
    }
  '' else configFilePath;

  mkBuildSupport = super: let
    self = import ./build-support {
      inherit (super) config;
      callPackage = pkgs.lib.callPackageWith (super // self);
      callPackages = pkgs.lib.callPackagesWith (super // self);
    };
  in self;

  baseModule = { lib, ... }: {
    options = {
      packages = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        default = {};
        description = "Available collections of games.";
      };
    };

    config._module.args.pkgs = pkgs // (mkBuildSupport pkgs) // {
      pkgsi686Linux = pkgsi686Linux // (mkBuildSupport pkgsi686Linux);
    };
  };

  packages = (pkgs.lib.evalModules {
    modules = [
      (if config == null then configFile else config)
      baseModule ./humblebundle ./steam ./itch ./gog ./foss
    ];
  }).config.packages;

in packages // mkBuildSupport pkgs
