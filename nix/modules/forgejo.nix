{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.services.forgejo;
in
{

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
      default = [ ];
      example = [ "git.vstov.dk" ];
      description = "Extra names the nginx vhost also answers to.";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Loopback port Forgejo listens on, behind nginx.";
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 22;
      description = "SSH port shown in clone URLs, and opened in the firewall.";
    };

    reverseProxy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Put Forgejo behind nginx on port 80 instead of exposing it directly.";
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
        default = [ ];
        example = [ "/mnt/backup2/forgejo" ];
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
          DOMAIN    = cfg.domain;
          ROOT_URL  = "http://${cfg.domain}/";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = cfg.httpPort;
          SSH_PORT  = cfg.sshPort;
        };
        service.DISABLE_REGISTRATION = true;
      };

      dump = lib.mkIf cfg.backup.enable {
        enable    = true;
        backupDir = cfg.backup.dir;
        interval  = cfg.backup.interval;
        type      = "zip";
        age       = cfg.backup.age;
      };
    };

# ========================================================================
# DUMP, TIMER, AND OFF-SITE MIRROR
# ========================================================================

    systemd.services.forgejo-dump = lib.mkIf cfg.backup.enable {
      unitConfig.RequiresMountsFor = [ cfg.backup.dir ] ++ cfg.backup.mirrors;
    };

    systemd.timers.forgejo-dump = lib.mkIf cfg.backup.enable {
      timerConfig.Persistent = true;
    };

    systemd.services.forgejo-dump-mirror =
      lib.mkIf (cfg.backup.enable && cfg.backup.mirrors != [ ]) {
        description = "Mirror Forgejo dumps to secondary media";
        after    = [ "forgejo-dump.service" ];
        wantedBy = [ "forgejo-dump.service" ];
        unitConfig.RequiresMountsFor = [ cfg.backup.dir ] ++ cfg.backup.mirrors;

        serviceConfig = {
          Type = "oneshot";
          User = config.services.forgejo.user;
          ExecStart = map (
            mirror:
            "${lib.getExe pkgs.rsync} -rt --delete --no-perms --no-owner --no-group "
            + "${cfg.backup.dir}/ ${mirror}/"
          ) cfg.backup.mirrors;
        };
      };

# ========================================================================
# REVERSE PROXY AND FIREWALL
# ========================================================================

    services.nginx = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      recommendedProxySettings = true;
      recommendedGzipSettings  = true;
      virtualHosts.${cfg.domain} = {
        serverAliases = cfg.aliases;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.httpPort}";
        };
      };
    };

    networking.firewall.allowedTCPPorts =
      lib.optional cfg.reverseProxy.enable 80 ++ [ cfg.sshPort ];
  };
}
