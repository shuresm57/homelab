{ config, lib, pkgs, ... }: 

let
  cfg = config.homelab.services.forgejo;
in {
  # ==========================================================================
  # OPTIONS
  # ==========================================================================

  options.homelab.services.forgejo = {
    enable = lib.mkEnableOption "the homelab Forgejo instance";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "git.home.arpa";
      description = "Domain Forgejo serves on, and the vhost nginx answers to.";
    };

    aliases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["git.vstov.dk"];
      description = "Extra names the nginx vhost also answers to.";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Loopback port Forgejo listens on, behind nginx.";
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = "SSH port shown in clone URLs, and opened in the firewall.";
    };

    reverseProxy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Put Forgejo behind nginx on port 80 instead of exposing it directly.";
    };

    anubis.enable = lib.mkEnableOption ''
      Anubis in front of the public aliases, so browsers solve a proof-of-work
      challenge before reaching Forgejo. Git and API clients bypass it
    '';

    # ========================================================================
    # SINGLE SIGN-ON
    # ========================================================================

    oidc = {
      enable = lib.mkEnableOption "login through an OpenID Connect provider only";

      name = lib.mkOption {
        type = lib.types.str;
        default = "keycloak";
        description = "Name of the auth source; also the path segment in /user/oauth2/<name>.";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "forgejo";
        description = "Client ID registered in the provider. The secret is OIDC_SECRET in /etc/forgejo/oidc.env.";
      };

      discoveryUrl = lib.mkOption {
        type = lib.types.str;
        example = "https://auth.vstov.dk/realms/homelab/.well-known/openid-configuration";
        description = "The provider's OpenID Connect discovery document.";
      };

      adminGroup = lib.mkOption {
        type = lib.types.str;
        default = "forgejo-admins";
        description = "Members of this group in the `groups` claim become site admins.";
      };
    };

    # ========================================================================
    # DUMP TO REMOVABLE MEDIA
    # ========================================================================

    backup = {
      enable = lib.mkEnableOption "periodic dumps via the built-in forgejo dump command";

      dir = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/backup1/forgejo";
        description = ''
          Directory the dumps are written to. Give it a directory of its own:
          retention deletes everything in here older than {option}`backup.age`.
        '';
      };

      mirrors = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["/mnt/backup2/forgejo"];
        description = "Directories {option}`backup.dir` is mirrored to after every dump.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "03:00";
        description = "When to dump, in {manpage}`systemd.time(7)` format.";
      };

      age = lib.mkOption {
        type = lib.types.str;
        default = "28d";
        description = "Dumps older than this are pruned from {option}`backup.dir`.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # ========================================================================
    # THE FORGE
    # ========================================================================

    services.forgejo = {
      enable = true;
      database.type = "sqlite3";

      settings = {
        server = {
          DOMAIN = cfg.domain;
          ROOT_URL = "https://git.vstov.dk/";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = cfg.httpPort;
          SSH_PORT = cfg.sshPort;
          START_SSH_SERVER = true;
          SSH_LISTEN_PORT = cfg.sshPort;
        };
        service = {
          # With OIDC on, accounts are only created on first login through the provider.
          DISABLE_REGISTRATION = !cfg.oidc.enable;
          # REQUIRE_SIGNIN_VIEW = true; Disabled for now
        } // lib.optionalAttrs cfg.oidc.enable {
          ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          ENABLE_INTERNAL_SIGNIN = false;
          # HTTPS git then needs an access token; SSH is unaffected.
          ENABLE_BASIC_AUTHENTICATION = false;
        };
        oauth2_client = lib.mkIf cfg.oidc.enable {
          ENABLE_AUTO_REGISTRATION = true;
          # Links to the existing account with the same username/email.
          ACCOUNT_LINKING = "auto";
          USERNAME = "nickname";
          OPENID_CONNECT_SCOPES = "openid email profile";
          UPDATE_AVATAR = true;
        };
      };

      dump = lib.mkIf cfg.backup.enable {
        enable = true;
        backupDir = cfg.backup.dir;
        interval = cfg.backup.interval;
        type = "zip";
        age = cfg.backup.age;
      };
    };

    # ========================================================================
    # OIDC AUTH SOURCE
    # ========================================================================

    # Auth sources live in the database, not app.ini, so they are seeded here:
    # add on first start, update in place on every later one.
    systemd.services.forgejo = lib.mkIf cfg.oidc.enable {
      after = ["keycloak.service"];
      wants = ["keycloak.service"];
      serviceConfig.EnvironmentFile = "/etc/forgejo/oidc.env";

      preStart = let
        forgejo = lib.getExe config.services.forgejo.package;
        flags = lib.escapeShellArgs [
          "--name" cfg.oidc.name
          "--provider" "openidConnect"
          "--key" cfg.oidc.clientId
          "--auto-discover-url" cfg.oidc.discoveryUrl
          "--scopes" "openid email profile"
          "--group-claim-name" "groups"
          "--admin-group" cfg.oidc.adminGroup
          "--skip-local-2fa"
        ];
      in lib.mkAfter ''
        id=$(${forgejo} admin auth list | ${lib.getExe pkgs.gawk} -v n=${lib.escapeShellArg cfg.oidc.name} '$2 == n { print $1 }')
        if [ -z "$id" ]; then
          ${forgejo} admin auth add-oauth ${flags} --secret "$OIDC_SECRET"
        else
          ${forgejo} admin auth update-oauth --id "$id" ${flags} --secret "$OIDC_SECRET"
        fi
      '';
    };

    # ========================================================================
    # DUMP, TIMER, AND OFF-SITE MIRROR
    # ========================================================================

    systemd.services.forgejo-dump = lib.mkIf cfg.backup.enable {
      unitConfig.RequiresMountsFor = [cfg.backup.dir] ++ cfg.backup.mirrors;
    };

    systemd.timers.forgejo-dump = lib.mkIf cfg.backup.enable {
      timerConfig.Persistent = true;
    };

    systemd.services.forgejo-dump-mirror = lib.mkIf (cfg.backup.enable && cfg.backup.mirrors != []) {
      description = "Mirror Forgejo dumps to secondary media";
      after = ["forgejo-dump.service"];
      wantedBy = ["forgejo-dump.service"];
      unitConfig.RequiresMountsFor = [cfg.backup.dir] ++ cfg.backup.mirrors;

      serviceConfig = {
        Type = "oneshot";
        User = config.services.forgejo.user;
        ExecStart =
          map (
            mirror:
              "${lib.getExe pkgs.rsync} -rt --delete --no-perms --no-owner --no-group "
              + "${cfg.backup.dir}/ ${mirror}/"
          )
          cfg.backup.mirrors;
      };
    };

    # ========================================================================
    # SCRAPER DEFENCE
    # ========================================================================

    services.anubis.instances.forgejo = lib.mkIf cfg.anubis.enable {
      settings.TARGET = "http://127.0.0.1:${toString cfg.httpPort}";
    };

    # The Anubis socket is group-owned by anubis.
    users.users.nginx.extraGroups = lib.mkIf cfg.anubis.enable [config.users.groups.anubis.name];

    # ========================================================================
    # REVERSE PROXY AND FIREWALL
    # ========================================================================

    services.nginx = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      recommendedProxySettings = true;
      recommendedGzipSettings = true;

      virtualHosts = let
        direct = "http://127.0.0.1:${toString cfg.httpPort}";
        geoblock = ''
          if ($allowed_country = no) { return 403; }
        '';

        # Skip the login page and go straight to the provider.
        loginRedirect = lib.optionalAttrs cfg.oidc.enable {
          "= /user/login".return = "302 /user/oauth2/${cfg.oidc.name}";
        };

        # Git over HTTPS and API clients cannot solve a challenge, so they skip Anubis.
        anubisFront = lib.optionalAttrs cfg.anubis.enable {
          "~ (/info/refs|/git-upload-pack|/git-receive-pack)$" = {
            proxyPass = direct;
            extraConfig = geoblock;
          };
          "/api/" = {
            proxyPass = direct;
            extraConfig = geoblock;
          };
        };
      in {
        ${cfg.domain}.locations = {
          "/".proxyPass = direct;
        } // loginRedirect;
      } // lib.genAttrs cfg.aliases (alias: {
        forceSSL = true;
        enableACME = true;
        locations = {
          "/" = {
            proxyPass =
              if cfg.anubis.enable
              then "http://unix:${config.services.anubis.instances.forgejo.settings.BIND}"
              else direct;
            extraConfig = geoblock;
          };
        } // loginRedirect // anubisFront;
      });
    };

    networking.firewall.allowedTCPPorts =
      lib.optional cfg.reverseProxy.enable 80
      ++ lib.optional (cfg.aliases != []) 443
      ++ [cfg.sshPort];
  };
}
