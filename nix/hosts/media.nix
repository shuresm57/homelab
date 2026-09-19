# nix/hosts/media.nix
{ ... }:
{
  networking.hostName = "media";

  homelab.storage.zfs = {
    enable = true;
    hostId = "8f3c1d20";           # head -c4 /dev/urandom | od -A none -t x4
    pools  = [ "tank" ];
  };

  fileSystems."/data/media"  = { device = "tank/media"; fsType = "zfs"; };
  fileSystems."/data/.state" = { device = "tank/state"; fsType = "zfs"; };

  homelab.services.media.enable = true;
}
