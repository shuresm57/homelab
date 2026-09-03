{ config, lib, pkgs, ... }:
let
  # Source of truth: docs/network-inventory.md
  records = {
    "dns.home.arpa"      = "192.168.0.64";
    "git.home.arpa"      = "192.168.0.61";
    "truenas.home.arpa"  = "192.168.0.65";
    "jellyfin.home.arpa" = "192.168.0.66";
    "ollama.home.arpa"   = "192.168.0.67";
    "grafana.home.arpa"  = "192.168.0.68";
    "hp16.home.arpa"     = "192.168.0.125";
    "hp32.home.arpa"     = "192.168.0.129";
    "dell.home.arpa"     = "192.168.0.254";
  };
in
{
  networking.hostName = "dns";

  # A DNS server must not resolve through itself, or it cannot bootstrap.
  networking.nameservers = [ "192.168.0.1" ];

  # Keep resolved for this host's own resolution, but free port 53 for FTL.
  services.resolved.settings.Resolve = {
    DNSStubListener = false;
    MulticastDNS = false;
  };

  environment.systemPackages = [
    config.services.pihole-ftl.package
    pkgs.pihole
  ];

  systemd.services.pihole-ftl-setup.serviceConfig.SuccessExitStatus = [ 1 ];

  services.pihole-ftl = {
    enable = true;

    openFirewallDNS = true;
    openFirewallWebserver = true;
    queryLogDeleter.enable = true;

    lists = [{
      url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
      type = "block";
      enabled = true;
      description = "Steven Black's HOSTS";
    }];

    settings = {
      dns = {
        domain = "home.arpa";
        domainNeeded = true;
        expandHosts = true;
        interface = "eth0";
        upstreams = [ "1.1.1.1" "9.9.9.9" ];
        hosts = lib.mapAttrsToList (name: ip: "${ip} ${name}") records;
      };

      webserver = {
        api = {
          cli_pw = true; # required by the assertion on `lists`
          pwhash = "$BALLOON-SHA256$v=1$s=1024,t=32$LnnWg2dsSd2u3HjgvYOPiA==$W1wR/V8KvhdtxFXpekyVQ9BiAjhryr7sVZWAxySdPOM=";
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

  services.pihole-web = {
    enable = true;
    hostName = "dns.home.arpa";
    ports = [ 80 ];
  };
}
