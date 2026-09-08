{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.services.pihole;
in
{

# ==========================================================================
# OPTIONS
# ==========================================================================

  options.homelab.services.pihole = {
    enable = lib.mkEnableOption "the homelab Pi-hole resolver";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "home.arpa";
      description = "Local domain FTL is authoritative for.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "Interface FTL answers DNS queries on.";
    };

    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" "9.9.9.9" ];
      description = "Upstream resolvers queries are forwarded to.";
    };

    records = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = import ../data/network.nix;
      defaultText = lib.literalExpression "import ../data/network.nix";
      example = { "git.home.arpa" = "192.168.0.61"; };
      description = "Local A records, as hostname -> IP.";
    };

    blocklists = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "URL of the domain list.";
          };
          type = lib.mkOption {
            type = lib.types.enum [ "allow" "block" ];
            default = "block";
            description = "Whether domains on this list are explicitly allowed, or blocked.";
          };
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether this list is enabled.";
          };
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Description of the list.";
          };
        };
      });
      default = [{
        url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
        description = "Steven Black's HOSTS";
      }];
      description = "Domain lists FTL subscribes to.";
    };

# ========================================================================
# DASHBOARD
# ========================================================================

    web = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Serve the Pi-hole dashboard.";
      };

      hostName = lib.mkOption {
        type = lib.types.str;
        default = "dns.${cfg.domain}";
        defaultText = lib.literalExpression ''"dns.''${config.homelab.services.pihole.domain}"'';
        description = "Domain name the dashboard is served under.";
      };

      ports = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ 80 ];
        description = "Ports the dashboard listens on.";
      };

      passwordHash = lib.mkOption {
        type = lib.types.str;
        description = ''
          Balloon hash of the web interface password, as produced by
          {command}`pihole-FTL --hash`. Ends up in the world-readable Nix store.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {

# ========================================================================
# ADMIN TOOLING, AND THE FTL SETUP QUIRK
# ========================================================================

    environment.systemPackages = [
      config.services.pihole-ftl.package
      pkgs.pihole
    ];

    systemd.services.pihole-ftl-setup.serviceConfig.SuccessExitStatus = [ 1 ];

# ========================================================================
# RESOLVER: UPSTREAMS, LOCAL RECORDS, BLOCKING
# ========================================================================

    services.pihole-ftl = {
      enable = true;

      openFirewallDNS = true;
      openFirewallWebserver = true;
      queryLogDeleter.enable = true;

      lists = cfg.blocklists;

      settings = {
        dns = {
          domain = cfg.domain;
          domainNeeded = true;
          expandHosts = true;
          interface = cfg.interface;
          upstreams = cfg.upstreams;
          hosts = lib.mapAttrsToList (name: ip: "${ip} ${name}") cfg.records;
        };

        webserver = {
          api = {
            cli_pw = true; # required by the assertion on `lists`
            pwhash = cfg.web.passwordHash;
          };
          session.timeout = 43200; # 12h; default is 1800
        };

        ntp = {
          ipv4.active = false;
          ipv6.active = false;
          sync.active = false;
        };
      };
    };

# ========================================================================
# DASHBOARD
# ========================================================================

    services.pihole-web = lib.mkIf cfg.web.enable {
      enable = true;
      hostName = cfg.web.hostName;
      ports = cfg.web.ports;
    };
  };
}
