{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.storage.zfs;
in
{
  options.homelab.storage.zfs = {
    enable = lib.mkEnableOption "ZFS";

    hostId = lib.mkOption {
      type = lib.types.str;
      description = "8 hex characters, unique to this machine. ZFS refuses to work without it.";
    };

    pools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "tank" ];
      description = "Pools this host owns. Datasets are mounted via fileSystems, not from here.";
    };

    autoScrub = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    scrubInterval = lib.mkOption {
      type = lib.types.str;
      default = "monthly";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.supportedFilesystems = [ "zfs" ];
    networking.hostId = cfg.hostId;
    environment.systemPackages = [ pkgs.zfs ];

    services.zfs.autoScrub = {
      enable = cfg.autoScrub;
      interval = cfg.scrubInterval;
    };
  };
}
