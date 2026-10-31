# nix/hosts/media.nix
{ ... }:
{
  # Not in modules/default.nix: it imports nixarr unconditionally.
  imports = [../modules/media.nix];

  networking.hostName = "media";

  homelab.storage.zfs = {
    enable = true;
    hostId = "8f3c1d20";           # head -c4 /dev/urandom | od -A none -t x4
    pools  = [ "tank" ];

    standby = {
      enable = true;
      disks = [
        "wwn-0x5000c500838e8f1f"   # ST4000NM0034, sleeps after 15 min
        "wwn-0x5000c50056c939c3"   # ST4000NM0023, sleeps after 60 min
        "wwn-0x5000c500838e6a2f"   # ST4000NM0034
        "scsi-35000c50056d0ca73"   # ST4000NM0023
      ];
    };
  };

  fileSystems."/data/media"  = { device = "tank/media"; fsType = "zfs"; };
  # Old home of the nixarr state, which now lives in /var/lib/nixarr. Still
  # mounted as the copy to migrate from; drop it once that is done. A mount
  # that nothing writes to does not keep the disks awake.
  fileSystems."/data/.state" = { device = "tank/state"; fsType = "zfs"; };

  homelab.services.media = {
    enable = true;
    qbittorrent = true;

    # Abyss' Spotlight carousel, injected into jellyfin-web. The theme's CSS is
    # not declarative -- it lives in Jellyfin's own database. Paste
    #   @import url('https://cdn.jsdelivr.net/gh/AumGupta/abyss-jellyfin@main/abyss.css');
    # into Dashboard > General > Custom CSS once, and set
    # Settings > Display > Theme to Dark.
    abyssSpotlight = true;

    vpn = {
      enable = true;

      # A string, not a Nix path: `./...` would copy the private key into the
      # world-readable store. The file lives only on this machine, 0400 root.
      wgConf = "/data/.secret/vpn/wg.conf";

      # Verify the tunnel with: systemctl status vpn-test-service
      testService = true;
    };
  };
}
