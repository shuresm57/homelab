{ pkgs, ... }:
{
  imports = [ ../data/geoblock.nix ];

  networking.hostName = "git";

  services.nginx.package = pkgs.nginx.override {
    modules = [ pkgs.nginxModules.geoip2 ];
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "vstov@protonmail.com";
  };

  homelab.services.forgejo = {
    enable  = true;
    domain  = "git.home.arpa";
    aliases = [ "git.vstov.dk" ];
    sshPort = 2222;

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
