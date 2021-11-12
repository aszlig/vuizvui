{ config, pkgs, lib, ... }:

let
  myLib  = import ./lib.nix  { inherit pkgs lib; };
  myPkgs = import ./pkgs.nix { inherit pkgs lib myLib; };

  hakuHostName = "haku.profpatsch.de";

  youtube2audiopodcastPort = 1339;
  youtube2audiopodcastSubdir = "/halp";

  sshPort = 7001;
  warpspeedPort = 1338;
  wireguardPortUdp = 6889;
  tailscaleInterface = "tailscale0";
  tailscaleAddress = "100.76.60.85";
  gonicPortTailscale = 4747;
  sambaPortTailscale = 445;

  ethernetInterface = "enp0s20";
  wireguard = {
    port = wireguardPortUdp;
    interface = "wg0";
    internalNetwork =
      let genIp = cidr: lastByte: "10.42.0.${toString lastByte}/${toString cidr}";
      in {
        addr = genIp 32;
        range = genIp 24 0;
        server = genIp 24 1;
      };
  };

  myKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDNMQvmOfon956Z0ZVdp186YhPHtSBrXsBwaCt0JAbkf/U/P+4fG0OROA++fHDiFM4RrRHH6plsGY3W6L26mSsCM2LtlHJINFZtVILkI26MDEIKWEsfBatDW+XNAvkfYEahy16P5CBtTVNKEGsTcPD+VDistHseFNKiVlSLDCvJ0vMwOykHhq+rdJmjJ8tkUWC2bNqTIH26bU0UbhMAtJstWqaTUGnB0WVutKmkZbnylLMICAvnFoZLoMPmbvx8efgLYY2vD1pRd8Uwnq9MFV1EPbkJoinTf1XSo8VUo7WCjL79aYSIvHmXG+5qKB9ed2GWbBLolAoXkZ00E4WsVp9H philip@nyx";

in

{
  imports = [
    ./base-server.nix
  ];

  config = {

    # TODO abstract out
    vuizvui.modifyNixPath = false;
    nix.nixPath = [
      "nixpkgs=${with pkgs.vuizvui.profpatsch; filterSourceGitignoreWith {
          gitignoreLines =
            readGitignoreFile "${toString pkgs.path}/.gitignore";
          globMap = glob:
            # filter out the non-rooted file globs,
            # because those take forever to filter
            # (10(!) seconds evaluation time in my test).
            if (!glob.isDir && !glob.isRooted)
            then null
            else glob;
        } pkgs.path}"
      # TODO?
      # "vuizvui=/root/vuizvui"
      # TODO: nicer?
      "nixos-config=${pkgs.writeText "haku-configuration.nix" ''
        (import <vuizvui/machines>).profpatsch.haku.config
      ''}"
    ];

    vuizvui.user.profpatsch.server.sshPort = sshPort;

    boot.loader.grub.device = "/dev/sda";

    fileSystems = {
      "/" = {
        device = "/dev/sda3";
        fsType = "ext4";
      };
      "/boot" = {
        device = "/dev/sda2";
        fsType = "ext4";
      };
    };

    environment.systemPackages = with pkgs; [
      mktorrent                         # torrent file creator
      pkgs.vuizvui.profpatsch.warpspeed # trivial http file server
    ];

    users.groups.data-seeding = {};

    users.users = {
      root.openssh.authorizedKeys.keys = [ myKey ];

      rtorrent = {
        isNormalUser = true;
        extraGroups = [ "data-seeding" ];
      };
      vorstand = {
        isNormalUser = true;
        openssh.authorizedKeys.keys = [ myKey
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCUgS0VB5XayQobQfOi0tYeqpSSCXzftTKEyII4OYDhuF0/CdXSqOIvdqnWQ8933lPZ5234qCXCniIlRJpJQLBPJdJ7/XnC6W37asuft6yVYxTZnZat8edCuJETMvwZJZNttxHC04k3JPf9RMj25luICWabICH5XP9Mz3GoWSaOz7IOm7jiLQiF3UtiFOG06w76d3UfcIVbqjImwWv8nysphi9IQfL0XgC24zNE6LSeE7IN5xTOxoZxORQGsCEnFNCPevReNcSB0pI9xQ1iao7evaZkpzT4D4iQ/K7Ss8dsfFWN30NPMQS5ReQTUKtmGn1YlgkitiYTEXbMjkYbQaQr daniel@shadow"
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCtfWeIH7YZpWUUOZ3oC5FB2/J+P3scxm29gUQdVij/K0TuxW1yN/HtcvrO1mwSshS6sNZ2N6/Kb6+kuGyx1mEnaFt87K5ucxC7TNqiURh4eeZE1xX7B5Ob8TVegrBxoe+vcfaoyxn7sUzgF719H0aYC7PP6p3AIbhq3hRLcvY26u9/gZ39H79A71wCunauvpcnpb+rqyJMN6m2YoeOcoloe7wUDI8Xw5dUetHpNKn9k1vzS16CdwP4pAKI8aBtdNK7ZojVMe9LfBG8HHPr9K+cwcaxQuXkFBJzrfrtBCfQwrgWppsu/W/kGBs1ybku2bOFI5UXJBnsraXQqr1NLIfL phj@phj-X220"
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDj8dla7nOE7RSho2/9LAn+DANYkB1BmMoNryzTQ5mUJWukf5coCc+aNJcXYeu5dSTEicW2qQuD8mt8SDI5Qzv4oSpIYEsd0j4eW/BlC5XYd+4jS7Hfk/a1mJjMG7jdvOUtK3lLtrKaHxVUUjqdxKzzFBZlPov6FgHSJ//h1HxreV/Y0jL94qSvK39FZde5xlV/wQBvpglrMNu7FFWqyeKrOZ7U8D70scFliIuPok/02iQ31P+ncUfV3XrFyJodQq8J3hYEorGVKp3nNM1zaLlg8uqHk18Zt0GFnEAClBrC13yjM0jpMvaMyuXMaWuKeqsBZeUyaSo1j6BNsW/bFjiJ thomas-glamsch@gmx.de"
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCneS9f0u6sITEzKULgIK7LGKskPpyXlQoSLB6aYAS9ZUkZXHh97XwIQqv20/edsAwpKhSSw//n08bvlYjpUSDAg9V/iZzdEV1M7fxek1c0rxtFxbeCds5K67JV+wGEusVyQdtmVzyshBBg+Mk/66E3KgqMyjCyGPk/0qWaj6187DOxerbXI5QkO7lCPIa5jP2YR4yzmFomcGb4PqpPlWfOcjjEjtpenQkhy7iS0ukfkQ9jhIcppuvkZ9A8PL/ccHDNVg0YKNJbsviB5MwKm/6drK87fprP9SP0i7QZsdKhaaW3rQtzCiWup4Avwx91VfeLvef8JJnmDrx+tR7azdGCiiRQvLakT2aIyMSTcDG41PYsesFvqBhRidSgzdZ4I2jjT1iHL4XREQVSjB5voAFdXHrndZj9PT8mTMo1RsdM1YMspHD1ohn2a3YkzKHD6g1n0UM379lyJ2mBEA1w+Nb48s60Mecuy2MlFgN6MbwYXifJkm806nI09ExEfgan8JvWOUQLgCDtp4mGt62vYMmBb5UqyUpvTcPbxoAbpHx+LEAD9Q0OE8S8WGnmkXxnnP2fL1fkcL1wjwvDbW0q9ezl9SrMfxcd+n46kbkYnSJ8HwZSZPX3wn2FAqIAKR+46BSsXW5FTo0xwR9wEjaBC7/6PxcxmAivGJZzYUZ0cjCCOw== lisanne.wolters@gmx.net"
        ];
      };

      youtube2audiopodcast = {
        isSystemUser = true;
        group = "youtube2audiopodcast";
      };
    };

    # semi-tmp
    vuizvui.services.drawpile = {
      enable = true;
      configFile = ''
        [config]
        serverTitle = bsalc
        sessionSizeLimit = 200MB
        sessionCountLimit = 1
        persistence = true
        idleTimeLimit = 0
        title = Welcome to the bsalc server!
      '';
    };

    vuizvui.services.profpatsch.gonic = {
      enable = true;
      listenAddress = "${tailscaleAddress}:${toString gonicPortTailscale}";
      musicDir = "/data/seeding";
      musicDirGroup = "data-seeding";
      podcastDir = "/data/podcasts";
      podcastDirGroup = "data-seeding";
      scanIntervalMinutes = 10;
    };

    services.samba = {
      enable = true;
      enableNmbd = false;
      enableWinbindd = false;
      nsswins = false;
      extraConfig = ''
        # only listen to tailscale
        interfaces = ${tailscaleInterface}
        smb ports = ${toString sambaPortTailscale}
      '';
      shares = {
        data-seeding = {
          "path" = "/data/seeding";
          "read only" = "yes";
          "browsable" = "yes";
          "guest ok" = "yes";
        };
      };
    };
    # somewhat hacky, but we want tailscale to be up
    systemd.services.samba-smbd.wants = [ "tailscaled.service" ];
    systemd.services.samba-smbd.after = [ "tailscaled.service" ];

    systemd.services.warpspeed =
      let user = config.users.users.rtorrent;
      in {
        description = "internally served public files (see nginx)";
        wantedBy = [ "default.target" ];
        serviceConfig.WorkingDirectory = "${user.home}/public";
        # *6: all hosts, v6 preferred
        script = ''${pkgs.vuizvui.profpatsch.warpspeed}/bin/warpspeed "*6" ${toString warpspeedPort}'';
        serviceConfig.User = config.users.users.rtorrent.name;
      };

    systemd.services.youtube2audiopodcast =
      let user = config.users.users.youtube2audiopodcast;
      in {
        description = "serve a youtube playlist as rss";
        wantedBy = [ "default.target" ];
        script = "${pkgs.vuizvui.profpatsch.youtube2audiopodcast {
          url = "https://${hakuHostName}${youtube2audiopodcastSubdir}";
          internalPort = toString youtube2audiopodcastPort;
        }}";
        serviceConfig.User = config.users.users.youtube2audiopodcast.name;
      };


    security.acme.acceptTerms = true;
    security.acme.email = "mail@profpatsch.de";

    services.nginx = {
      enable = true;
      virtualHosts.${hakuHostName} = {
        forceSSL = true;
        enableACME = true;
        locations."/pub/" = {
          proxyPass = "http://127.0.0.1:${toString warpspeedPort}/";
        };
        locations."${youtube2audiopodcastSubdir}/" = {
          proxyPass = "http://127.0.0.1:${toString youtube2audiopodcastPort}/";
        };
        locations."/".root =
          let lojbanistanSrc = pkgs.fetchFromGitHub {
            owner = "lojbanistan";
            repo = "lojbanistan.de";
            rev = "ef02aa8f074d0d5209839cd12ba7a67685fdaa05";
            sha256 = "1hr2si73lam463pcf25napfbk0zb30kgv3ncc0ahv6wndjpsvg7z";
          };
          in pkgs.runCommandLocal "lojbanistan-www" {} ''
            mkdir $out
            echo "coi do" > $out/index.html
            ${pkgs.imagemagick}/bin/convert \
              ${lojbanistanSrc}/design/flag-of-lojbanistan-icon.svg \
              -define icon:auto-resize=64,48,32,16 \
              $out/favicon.ico
          '';
        serverAliases = [ "lojbanistan.de" ];
      };
    };

    networking = {
      nat = {
        enable = true;
        externalInterface = ethernetInterface;
        internalInterfaces = [ wireguard.interface ];
      };

      hostName = "haku";
      firewall = {
        allowedTCPPorts = [
          80 443
          6882
          1337 2342 4223
          60100
        ];
        allowedUDPPorts = [
          wireguard.port
          60100
        ];

        interfaces.${tailscaleInterface} = {
          allowedTCPPorts = [
            gonicPortTailscale
            sambaPortTailscale
          ];
        };

        # forward wireguard connections to ethernet device (VPN)
        extraCommands = ''
          iptables -t nat -A POSTROUTING -s ${wireguard.internalNetwork.range} -o ${ethernetInterface} -j MASQUERADE
        ''
        # drop every other kind of forwarding, except from wg0 to epn (and bridge wg)
        + ''
          iptables -P FORWARD DROP
          iptables -A FORWARD -i ${wireguard.interface} -o ${ethernetInterface} -j ACCEPT
          iptables -A FORWARD -o ${wireguard.interface} -i ${ethernetInterface} -j ACCEPT
          iptables -A FORWARD -i ${wireguard.interface} -o ${wireguard.interface} -j ACCEPT
        '';
      };

      wireguard.interfaces.${wireguard.interface} = {
        ips = [ wireguard.internalNetwork.server ];
        listenPort = wireguard.port;
        privateKeyFile = "/root/keys/wg/vpn.priv";

        peers = [
          { # shiki (TODO: factor out)
            publicKey = "x3ko/R8PLzcyjVjqot9qmGBb3NrG/4JvgRkIOQMEsUA=";
            allowedIPs = [ (wireguard.internalNetwork.addr 2) ];
          }
          { # mushu
            publicKey = "Stx6N4/JurtAuYX+43WPOCLBqheE99O6WRvxW+sd3jw=";
            allowedIPs = [ (wireguard.internalNetwork.addr 3) ];
          }
        ];
      };


      nameservers = [
        "62.210.16.6"
        "62.210.16.7"
      ];
    };

    services.tailscale = {
      enable = true;
      # interfaceName = tailscaleInterface;
    };
  };
}
