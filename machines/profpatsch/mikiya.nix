{ config, lib, pkgs, ... }:

let
  myLib  = import ./lib.nix  { inherit pkgs lib; };
  myPkgs = import ./pkgs.nix { inherit pkgs lib myLib; };

  mkDevice = category: num: uuid: {
    name = "mikiya-${category}-crypt-${toString num}";
    device = "/dev/disk/by-uuid/${uuid}";
    keyFile = "/root/raid.key";
  };

  systemDevice = "/dev/disk/by-id/ata-MKNSSDCR60GB-DX_MKN1140A0000025162";
  systemPartition = {
    name = "mikiya-root";
    device = "/dev/disk/by-uuid/56910867-ed83-438a-b67c-c057e662c89e";
  };

  raidDevices = lib.imap (mkDevice "raid") [
    "f0069e04-d058-40b3-8f13-92f11c4c2546"
  ];



in {
  imports = [ ./base-server.nix ];

  config = {

    vuizvui.user.profpatsch.server.sshPort = 22;
    boot = {
      loader.grub.device = systemDevice;
      initrd = {
        network = {
          enable = true;
          ssh.enable = true;
          ssh.authorizedKeys = myLib.authKeys;
        };

        # decrypt root device
        luks.devices = [systemPartition];
      };
    };

    fileSystems."/" = {
      device = "/dev/mapper/mikiya-root";
      fsType = "ext4";
      options = [ "ssd" ];
    };

    /*
    # decrypt RAID with key from root
    environment.etc.crypttab.text =
      let luksDevice = dev: "${dev.name} ${dev.device} ${dev.keyFile} luks";
      in concatMapStringsSep "\n" luksDevice raidDevices;

    powerManagement = {
      # spin down raid drives after 30 minutes
      powerUpCommand =
        let driveStandby = drive: "${pkgs.hdparm}/sbin/hdparm -S 241 ${drive.device}";
        in concatMapStringsSep "\n" driveStandby raidDevices;
    */

    users.users = { inherit (myLib) philip; };

  };

}
