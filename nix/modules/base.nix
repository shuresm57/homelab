{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}: {
  # virtio drivers in the initrd, so the scsi0 disk is found at boot.
  imports = ["${modulesPath}/profiles/qemu-guest.nix"];

  # ==========================================================================
  # DISK LAYOUT, MATCHING THE NIXOS-GENERATORS 'HYBRID' IMAGE
  # ==========================================================================
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  boot.growPartition = true;

  # The Terraform module sets bios = "ovmf", so the VM boots UEFI.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # cloud-init writes systemd-networkd config, so make networkd the single
  # manager. Without this, dhcpcd also runs and the two fight over the NIC.
  networking.useNetworkd = true;

  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.fail2ban = {
    enable = true;
   # Ban IP after 2 failures
    maxretry = 2;
    ignoreIP = [
      # Whitelist some subnets
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
      "8.8.8.8" # whitelist a specific IP
      "nixos.wiki" # resolve the IP via DNS
    ];
    bantime = "24h"; # Ban IPs for one day on the first ban
    bantime-increment = {
      enable = true; # Enable increment of bantime after each violation
      formula = "ban.Time * math.exp(float(ban.Count+1)*banFactor)/math.exp(1*banFactor)";
      multipliers = "1 2 4 8 16 32 64";
      maxtime = "168h"; # Do not ban for more than 1 week
      overalljails = true; # Calculate the bantime based on all the violations
    };
    jails = {
      apache-nohome-iptables.settings = {
        # Block an IP address if it accesses a non-existent
        # home directory more than 5 times in 10 minutes,
        # since that indicates that it's scanning.
        filter = "apache-nohome";
        action = ''iptables-multiport[name=HTTP, port="http,https"]'';
        logpath = "/var/log/httpd/error_log*";
        backend = "auto";
        findtime = 600;
        bantime  = 600;
        maxretry = 5;
      };
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTNPKoS0uzB2lVA+I1BsZvB1ugFNw5hm2P/8LnjfR5K vss@Valdemars-MacBook-Pro.local"
  ];

  users.users.nixos = {
  isNormalUser = true;
  extraGroups = [ "wheel" ];
  };

  time.timeZone = "Europe/Copenhagen";

  nix.settings.experimental-features = ["nix-command" "flakes"];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    nano
    nettools
    dig
    tree
    tmux
    usbutils
  ];

  system.stateVersion = "25.05";
}
