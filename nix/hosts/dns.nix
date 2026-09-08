{ ... }:
{
  networking.hostName = "dns";

  # A DNS server must not resolve through itself, or it cannot bootstrap.
  networking.nameservers = [ "192.168.0.1" ];

  # Keep resolved for this host's own resolution, but free port 53 for FTL.
  services.resolved.settings.Resolve = {
    DNSStubListener = false;
    MulticastDNS = false;
  };

  homelab.services.pihole = {
    enable    = true;
    domain    = "home.arpa";
    interface = "eth0";
    upstreams = [ "1.1.1.1" "9.9.9.9" ];

    web = {
      enable   = true;
      hostName = "dns.home.arpa";
      ports    = [ 80 ];
      passwordHash = "$BALLOON-SHA256$v=1$s=1024,t=32$LnnWg2dsSd2u3HjgvYOPiA==$W1wR/V8KvhdtxFXpekyVQ9BiAjhryr7sVZWAxySdPOM=";
    };
  };
}
