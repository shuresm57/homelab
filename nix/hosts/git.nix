{ ... }:
{
  networking.hostName = "git";

  homelab.services.forgejo = {
    enable  = true;
    domain  = "git.home.arpa";
    aliases = [ "git.vstov.dk" ];

    backup = {
      enable  = true;
      dir     = "/mnt/backup1/forgejo";
      mirrors = [ "/mnt/backup2/forgejo" ];
    };
  };

  fileSystems."/mnt/backup1" = {
    device = "/dev/disk/by-uuid/6303-505B";
    fsType = "exfat";
    options = [ "uid=996" "gid=995" "nofail" ];
  };

  fileSystems."/mnt/backup2" = {
    device = "/dev/disk/by-uuid/4958-11F2";
    fsType = "vfat";
    options = [ "uid=996" "gid=995" "nofail" ];
  };

  boot.supportedFilesystems = [ "exfat" ];
}
