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
    maxretry = 3;
    ignoreIP = [
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
    ];
    bantime = "24h";
    bantime-increment = {
      enable = true;
      formula = "ban.Time * math.exp(float(ban.Count+1)*banFactor)/math.exp(1*banFactor)";
      maxtime = "168h";
      overalljails = true;
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
