# nix/modules/media.nix
{ config, lib, inputs, ... }:
let
  cfg = config.homelab.services.media;
in
{
  imports = [ inputs.nixarr.nixosModules.default ];

  # ==========================================================================
  # OPTIONS
  # ==========================================================================
  options.homelab.services.media = {
    enable = lib.mkEnableOption "the Nixarr media stack";

    mediaDir = lib.mkOption {
      type = lib.types.path;
      default = "/data/media";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/data/.state/nixarr";
    };

    jellyfin    = lib.mkOption { type = lib.types.bool; default = true; };
    sonarr      = lib.mkOption { type = lib.types.bool; default = true; };
    radarr      = lib.mkOption { type = lib.types.bool; default = true; };
    prowlarr    = lib.mkOption { type = lib.types.bool; default = true; };
    bazarr      = lib.mkOption { type = lib.types.bool; default = true; };
    seerr       = lib.mkOption { type = lib.types.bool; default = true; };
    qbittorrent = lib.mkOption { type = lib.types.bool; default = true; };
    lidarr      = lib.mkOption { type = lib.types.bool; default = false; };
    readarr     = lib.mkOption { type = lib.types.bool; default = false; };

    vpn = {
      enable = lib.mkEnableOption "confining the download client to WireGuard";

      wgConf = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/data/.secret/vpn/wg.conf";
        description = "wg-quick file from the VPN provider. Never inside this repository.";
      };
    };
  };

  # ==========================================================================
  # THE STACK
  # ==========================================================================
  config = lib.mkIf cfg.enable {
    nixarr = {
      enable = true;
      inherit (cfg) mediaDir stateDir;

      vpn = { inherit (cfg.vpn) enable wgConf; };

      jellyfin.enable = cfg.jellyfin;      # 8096, and nixarr.jellyfin.port is read-only
      sonarr.enable   = cfg.sonarr;        # 8989
      radarr.enable   = cfg.radarr;        # 7878
      prowlarr.enable = cfg.prowlarr;      # 9696
      bazarr.enable   = cfg.bazarr;        # 6767
      seerr.enable    = cfg.seerr;         # 5055, Jellyseerr
      lidarr.enable   = cfg.lidarr;
      readarr.enable  = cfg.readarr;

      qbittorrent = {
        enable     = cfg.qbittorrent;      # WebUI on 5252
        vpn.enable = cfg.vpn.enable;
        peerPort   = 6881;
      };
    };

    assertions = [
      {
        assertion = cfg.qbittorrent -> cfg.vpn.enable;
        message = ''
          homelab.services.media.qbittorrent requires vpn.enable.
          A torrent client must not run on the bare WAN address.
        '';
      }
      {
        assertion = cfg.vpn.enable -> cfg.vpn.wgConf != null;
        message = "homelab.services.media.vpn.enable requires vpn.wgConf.";
      }
    ];
  };
}
