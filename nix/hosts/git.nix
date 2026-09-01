{ config, lib, pkgs, ... }:
{
  networking.hostName = "git";

  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    settings = {
      server = {
        DOMAIN    = "git.home.arpa";
        ROOT_URL  = "http://git.home.arpa/";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = 3000;
        SSH_PORT  = 22;
      };
      service.DISABLE_REGISTRATION = true;
    };
  };

  fileSystems."/mnt/backup1" = {
  device = "/dev/disk/by-uuid/6303-505B";
  fsType = "exfat";
  options = [ "uid=996" "gid=995" "nofail" ];
  };

  fileSystems."/mnt/backup2" = {
  device = "/dev/disk/by-uuid/4958-11F2";
  fsType = "vfat";
  options = [ "uid=996" "gid=995" "nofail" ];
  };

  boot.supportedFilesystems = [ "exfat" ];

  systemd.services.forgejo-backup = {
  script = ''
    export FORGEJO_WORK_DIR=/var/lib/forgejo
    export FORGEJO_CUSTOM=/var/lib/forgejo/custom
    export HOME=/var/lib/forgejo
    ${config.services.forgejo.package}/bin/forgejo dump -c /var/lib/forgejo/custom/conf/app.ini --file /mnt/backup1/forgejo-backup-$(date +%F).zip
    cp /mnt/backup1/forgejo-backup-$(date +%F).zip /mnt/backup2/
  '';
  serviceConfig = {
    User = "forgejo";
    Type = "oneshot";
  };
  requires = [ "mnt-backup1.mount" "mnt-backup2.mount" ];
  after = [ "mnt-backup1.mount" "mnt-backup2.mount" ];
  };

  systemd.timers.forgejo-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
    };
  };
  
security.acme = {
  acceptTerms = true;
  defaults.email = "vstov@protonmail.com";
};

services.nginx.virtualHosts."git.home.arpa" = {
  serverAliases = [ "git.vstov.dk" ];
  forceSSL = true;
  enableACME = true;
  locations."/" = {
    proxyPass = "http://127.0.0.1:3000";
  };
};

  networking.firewall.allowedTCPPorts = [ 80 22 ];
}
