{ modulesPath, config, pkgs, lib, ... }:

let
  myLib  = import ./lib.nix  { inherit pkgs lib; };
  myPkgs = import ./pkgs.nix { inherit pkgs lib myLib; };

  hostname = "legosi";

  myKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDNMQvmOfon956Z0ZVdp186YhPHtSBrXsBwaCt0JAbkf/U/P+4fG0OROA++fHDiFM4RrRHH6plsGY3W6L26mSsCM2LtlHJINFZtVILkI26MDEIKWEsfBatDW+XNAvkfYEahy16P5CBtTVNKEGsTcPD+VDistHseFNKiVlSLDCvJ0vMwOykHhq+rdJmjJ8tkUWC2bNqTIH26bU0UbhMAtJstWqaTUGnB0WVutKmkZbnylLMICAvnFoZLoMPmbvx8efgLYY2vD1pRd8Uwnq9MFV1EPbkJoinTf1XSo8VUo7WCjL79aYSIvHmXG+5qKB9ed2GWbBLolAoXkZ00E4WsVp9H philip@nyx";

in {
  imports = [
    ./base-server.nix
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  config = {
    vuizvui.modifyNixPath = false;
    nix.nixPath = [
      "vuizvui=/root/vuizvui"
      "nixpkgs=/root/nixpkgs"
      # todo: nicer?
      "nixos-config=${pkgs.writeText "legosi-configuration.nix" ''
        (import <vuizvui/machines>).profpatsch.legosi.config
      ''}"
    ];

    vuizvui.user.profpatsch.server.sshPort = 7001;

    boot.loader.grub.device = "/dev/sda";
    # VPN support
    boot.extraModulePackages = [ config.boot.kernelPackages.wireguard ];

    fileSystems = {
      "/" = {
        device = "/dev/sda1";
        fsType = "ext4";
      };
    };

    networking = {
      hostName = hostname;
    };

    users.users = {
      root.openssh.authorizedKeys.keys = [ myKey ];
    };

    vuizvui.programs.profpatsch.weechat = {
      enable = true;
      authorizedKeys = [ myKey ];
      # redirect the bitlbee unix socket to a fake domain
      # because
      wrapExecStart = [
        "${pkgs.ip2unix}/bin/ip2unix"
        "-r"
        "addr=1.2.3.4,port=6667,path=${config.vuizvui.services.profpatsch.bitlbee.socketFile}"
      ];
    };
    users.users.weechat.extraGroups = [ "bitlbee" ];

    vuizvui.services.profpatsch.bitlbee = {
       enable = true;
    };

    # services.nginx = {
    #   enable = true;
    #   virtualHosts.${"profpatsch.de"} = {
    #     forceSSL = true;
    #     enableACME = true;
    #     locations."/" = {
    #       index = "index.html";
    #     };
    #     serverAliases = [ "lojbanistan.de" ];
    #   };
    # };

  };
}
