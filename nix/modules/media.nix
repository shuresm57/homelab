# nix/modules/media.nix
{ config, lib, inputs, ... }:
let
  cfg = config.homelab.services.media;

  # How the *arr services reach qBittorrent. It sits in the `wg` network
  # namespace, whose bridge address is 192.168.15.1; the arrs run on the host
  # side (192.168.15.5), which is inside qBittorrent's AuthSubnetWhitelist,
  # so no credentials are needed. qui, when enabled, takes the public port and
  # qBittorrent's own WebUI moves to an internal one.
  qbitFields = {
    host =
      if cfg.vpn.enable
      then "192.168.15.1"
      else "localhost";
    port =
      if config.nixarr.qbittorrent.qui.enable
      then config.nixarr.qbittorrent.qui.internalPort
      else config.nixarr.qbittorrent.webuiPort;
    useSsl = false;
  };
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
      # On the VM's own disk, not on tank: the arrs and Jellyfin write to
      # their databases constantly, which would keep the pool from spinning down.
      default = "/var/lib/nixarr";
    };

    jellyfin    = lib.mkOption { type = lib.types.bool; default = true; };
    sonarr      = lib.mkOption { type = lib.types.bool; default = true; };
    radarr      = lib.mkOption { type = lib.types.bool; default = true; };
    prowlarr    = lib.mkOption { type = lib.types.bool; default = true; };
    bazarr      = lib.mkOption { type = lib.types.bool; default = true; };
    seerr       = lib.mkOption { type = lib.types.bool; default = true; };
    qbittorrent = lib.mkOption { type = lib.types.bool; default = true; };
    lidarr      = lib.mkOption { type = lib.types.bool; default = false; };

    abyssSpotlight = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bake the Abyss theme's Spotlight carousel into jellyfin-web, by way of
        ../overlays/abyss-spotlight.nix. Off by default: it costs a local
        rebuild of the jellyfin server package, because jellyfin hardcodes the
        web root into its wrapper.

        Spotlight is only the carousel. The theme is the CSS line in
        Dashboard > General > Custom CSS, with Settings > Display > Theme on
        Dark -- see the overlay's header comment.
      '';
    };

    autoWire = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Declare the links between the services instead of clicking them into
        each web UI: qBittorrent as the download client in Sonarr/Radarr, and
        Sonarr/Radarr as applications in Prowlarr.

        nixarr only auto-configures a download client for Transmission, and
        leaves Prowlarr's application list empty, so without this the stack
        starts up completely unwired.

        This also relaxes `auth.required` to "DisabledForLocalAddresses" on
        Sonarr, Radarr and Prowlarr, which nixarr asserts is necessary for the
        application sync. API keys still apply; what goes away is the browser
        login for RFC1918 clients. Set false to keep the logins and wire the
        services by hand.
      '';
    };

    vpn = {
      enable = lib.mkEnableOption "confining the download client to WireGuard";

      wgConf = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/data/.secret/vpn/wg.conf";
        description = ''
          wg-quick file from the VPN provider. Never inside this repository:
          give an absolute path as a *string*, so the private key stays on the
          target machine instead of being copied world-readable into the store.
        '';
      };

      exposeOnLAN = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Let LAN clients reach the confined services. False restricts them to
          localhost, which is what you want behind a reverse proxy.
        '';
      };

      testService = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run nixarr's VPN test service, for checking the tunnel and DNS leaks.";
      };
    };
  };

  # ==========================================================================
  # THE STACK
  # ==========================================================================
  config = lib.mkIf cfg.enable {
    nixpkgs.overlays =
      lib.optional (cfg.jellyfin && cfg.abyssSpotlight) (import ../overlays/abyss-spotlight.nix);

    nixarr = {
      enable = true;
      inherit (cfg) mediaDir stateDir;

      vpn = {
        inherit (cfg.vpn) enable wgConf exposeOnLAN;
        vpnTestService.enable = cfg.vpn.testService;
      };

      jellyfin.enable = cfg.jellyfin;      # 8096, and nixarr.jellyfin.port is read-only
      sonarr.enable   = cfg.sonarr;        # 8989
      radarr.enable   = cfg.radarr;        # 7878
      prowlarr.enable = cfg.prowlarr;      # 9696
      bazarr.enable   = cfg.bazarr;        # 6767
      seerr.enable    = cfg.seerr;         # 5055, Jellyseerr
      lidarr.enable   = cfg.lidarr;
      # No readarr: Readarr is discontinued and this nixarr rev dropped the option.

      qbittorrent = {
        enable     = cfg.qbittorrent;      # qui WebUI on 5252
        vpn.enable = cfg.vpn.enable;
        peerPort   = 6881;
      };

      # --- Declarative wiring (see homelab.services.media.autoWire) ---------
      radarr.settings-sync.downloadClients = lib.mkIf (cfg.autoWire && cfg.qbittorrent && cfg.radarr) [
        {
          name = "qBittorrent";
          implementation = "QBittorrent";
          enable = true;
          fields = qbitFields // { movieCategory = "radarr"; };
        }
      ];

      sonarr.settings-sync.downloadClients = lib.mkIf (cfg.autoWire && cfg.qbittorrent && cfg.sonarr) [
        {
          name = "qBittorrent";
          implementation = "QBittorrent";
          enable = true;
          # Sonarr names this tvCategory where Radarr says movieCategory.
          fields = qbitFields // { tvCategory = "sonarr"; };
        }
      ];

      # Registers the nixarr-managed arrs as Prowlarr applications, so indexers
      # added in Prowlarr propagate to them. Defaults to false upstream.
      prowlarr.settings-sync.enable-nixarr-apps = lib.mkIf (cfg.autoWire && cfg.prowlarr) true;
    };

    # nixarr asserts the app sync needs this. It drops the browser login for
    # private-range clients only; API-key auth is untouched.
    services = lib.mkIf cfg.autoWire {
      prowlarr.settings.auth.required = lib.mkIf cfg.prowlarr "DisabledForLocalAddresses";
      radarr.settings.auth.required = lib.mkIf cfg.radarr "DisabledForLocalAddresses";
      sonarr.settings.auth.required = lib.mkIf cfg.sonarr "DisabledForLocalAddresses";
    };

    # The module opens what it turns on. Without this the services listen
    # correctly but answer only on loopback.
    networking.firewall.allowedTCPPorts =
      lib.optional cfg.jellyfin 8096
      ++ lib.optional cfg.sonarr 8989
      ++ lib.optional cfg.radarr 7878
      ++ lib.optional cfg.prowlarr 9696
      ++ lib.optional cfg.bazarr 6767
      ++ lib.optional cfg.seerr 5055
      ++ lib.optional cfg.qbittorrent 5252;

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
