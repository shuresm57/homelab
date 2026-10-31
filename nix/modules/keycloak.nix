{ config, lib, ... }:

let
  cfg = config.homelab.services.keycloak;
  upstream = "http://127.0.0.1:${toString cfg.httpPort}";
in {
  # ==========================================================================
  # OPTIONS
  # ==========================================================================

  options.homelab.services.keycloak = {
    enable = lib.mkEnableOption "the homelab Keycloak identity provider";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "auth.vstov.dk";
      description = "Public name Keycloak serves on, and the vhost nginx answers to.";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback port Keycloak listens on, behind nginx.";
    };

    lanSubnet = lib.mkOption {
      type = lib.types.str;
      default = "192.168.0.0/24";
      description = "The only subnet allowed to reach the admin console and the master realm.";
    };
  };

  config = lib.mkIf cfg.enable {

    # ========================================================================
    # THE IDENTITY PROVIDER
    # ========================================================================

    services.keycloak = {
      enable = true;

      database = {
        type = "postgresql";
        createLocally = true;
        # Written by hand on the host, like /etc/forgejo/oidc.env.
        passwordFile = "/etc/keycloak/db-password";
      };

      # Only used to create the first admin. Change it on first login.
      initialAdminPassword = "change-me";

      settings = {
        hostname = "https://${cfg.domain}";
        http-enabled = true;
        http-host = "127.0.0.1";
        http-port = cfg.httpPort;
        proxy-headers = "xforwarded";
      };
    };

    # ========================================================================
    # REVERSE PROXY
    # ========================================================================

    # The admin console logs in through the master realm, so both stay on the LAN.
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;

      virtualHosts.${cfg.domain} = {
        forceSSL = true;
        enableACME = true;
        locations = {
          "/" = {
            proxyPass = upstream;
            extraConfig = ''
              if ($allowed_country = no) { return 403; }
            '';
          };
        } // lib.genAttrs ["/admin" "/realms/master"] (_: {
          proxyPass = upstream;
          extraConfig = ''
            allow ${cfg.lanSubnet};
            deny all;
          '';
        });
      };
    };

    # Local clients (Forgejo's token exchange) reach nginx directly, not via hairpin NAT.
    networking.hosts."127.0.0.1" = [cfg.domain];

    networking.firewall.allowedTCPPorts = [80 443];
  };
}
