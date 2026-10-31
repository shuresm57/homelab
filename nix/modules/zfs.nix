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

    standby = {
      enable = lib.mkEnableOption "the disks' own standby timer (SAS power conditions)";

      disks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "wwn-0x5000c500838e8f1f" ];
        description = ''
          Whole-disk names under /dev/disk/by-id (no -part suffix). Each gets
          STANDBY_Z enabled at boot, with the drive's own timer left as it is:
          these Seagates refuse anything below their default, 15 min on the
          ST4000NM0034 and 60 min on the ST4000NM0023.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    boot.supportedFilesystems = [ "zfs" ];

    # The 26.11 default, set early. Importing a pool that another machine still
    # has held open is how ZFS loses data; refuse rather than force.
    boot.zfs.forceImportRoot = false;
    networking.hostId = cfg.hostId;

    # Without this cfg.pools was decorative: a pool only gets imported at boot
    # if something references it, and datasets mounted via fileSystems only
    # cover the pools those entries happen to name.
    boot.zfs.extraPools = cfg.pools;
    environment.systemPackages = [ pkgs.zfs ];

    services.zfs.autoScrub = {
      enable = cfg.autoScrub;
      interval = cfg.scrubInterval;
    };

    # Not hd-idle: it sends STOP UNIT, after which a SAS disk stays down until
    # it gets START UNIT, so the next read fails with "Logical unit not ready"
    # and the pool suspends -- which is what happened on 2026-10-20. A standby
    # the drive entered by its own timer is left again by any read (CCF_STAND=1
    # on these disks), tested at 9-14 s to spin up.
    #
    # Set without --save, so the drive forgets it on power loss and this unit
    # is the only place it lives.
    systemd.services.disk-standby = lib.mkIf (cfg.standby.enable && cfg.standby.disks != [ ]) {
      description = "Enable the standby timer on the pool's disks";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-import.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStrings (d: ''
        ${pkgs.sdparm}/bin/sdparm --set=STANDBY_Z=1 /dev/disk/by-id/${d}
      '') cfg.standby.disks;
    };
  };
}
