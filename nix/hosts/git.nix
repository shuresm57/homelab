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
        HTTP_ADDR = "127.0.0.1"; # only nginx reaches it
        HTTP_PORT = 3000;
        SSH_PORT  = 22;
      };
      service.DISABLE_REGISTRATION = true; # single-user lab
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedGzipSettings  = true;

    virtualHosts."git.home.arpa" = {
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 22 ];
}
