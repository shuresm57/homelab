# DNS and IP table for Pi-hole. Consumed by homelab.services.pihole.records,
# which is typed attrsOf str, every entry, must be hostname -> IP, nothing else.
{
  "home.home.arpa" = "192.168.0.65";
  "dns.home.arpa" = "192.168.0.64";
  "git.home.arpa" = "192.168.0.61";
  "git.vstov.dk" = "192.168.0.61";
  "auth.vstov.dk" = "192.168.0.61";
  "media.home.arpa" = "192.168.0.66";
  "jellyfin.home.arpa" = "192.168.0.66";
  "ollama.home.arpa" = "192.168.0.67";
  "grafana.home.arpa" = "192.168.0.68";
  "hp16.home.arpa" = "192.168.0.125";
  "hp32.home.arpa" = "192.168.0.129";
  "dell.home.arpa" = "192.168.0.254";
}
