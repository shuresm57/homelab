{ config, pkgs, lib, modulesPath, ... }:
{
  # virtio drivers in the initrd, so the scsi0 disk is found at boot.
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  # --- disk layout, matching the nixos-generators 'hybrid' image ------------
  fileSystems."/" = {
    device     = "/dev/disk/by-label/nixos";
    fsType     = "ext4";
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
      PermitRootLogin        = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTNPKoS0uzB2lVA+I1BsZvB1ugFNw5hm2P/8LnjfR5K vss@Valdemars-MacBook-Pro.local"
  ];

  time.timeZone = "Europe/Copenhagen";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  nix.gc = {
    automatic = true;
    dates     = "weekly";
    options   = "--delete-older-than 30d";
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
  ];

  system.stateVersion = "25.05";
}
