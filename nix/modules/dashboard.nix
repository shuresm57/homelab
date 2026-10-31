# nix/modules/dashboard.nix
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.dashboard;

  # Addresses come from the same table Pi-hole is generated from, so a host
  # that moves is edited in exactly one place.
  net = import ../data/network.nix;
  ip = name: net."${name}.home.arpa";

  # Links use names, because that is what you want in the address bar.
  # Health checks use addresses, so the dashboard still tells you the truth
  # when the thing that is down happens to be DNS.
  entry = {
    name,
    host,
    port,
    description,
    icon,
    scheme ? "http",
    path ? "",
  }: {
    ${name} = {
      href = "${scheme}://${host}.home.arpa:${toString port}${path}";
      siteMonitor = "${scheme}://${ip host}:${toString port}${path}";
      inherit description icon;
    };
  };
in {
  options.homelab.services.dashboard = {
    enable = lib.mkEnableOption "the homelab dashboard (gethomepage)";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "home.home.arpa";
      description = "Name nginx serves the dashboard under, on port 80.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = ''
        Loopback port Homepage listens on, behind nginx. It runs as a
        DynamicUser with no CAP_NET_BIND_SERVICE, so it cannot take port 80
        itself -- same reason Forgejo sits behind nginx rather than binding 80.
      '';
    };

    title = lib.mkOption {
      type = lib.types.str;
      default = "homelab";
      description = "Heading shown at the top of the page.";
    };

    extraAllowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Extra Host header values the dashboard will answer to. Homepage
        rejects anything not on this list, which is why reaching it by a new
        name or address needs an entry here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.homepage-dashboard = {
      enable = true;
      listenPort = cfg.port;
      # nginx owns the public port; Homepage stays on loopback.
      openFirewall = false;

      # nginx passes the browser's Host header through, so this must list the
      # names people actually type, not the loopback port Homepage binds.
      allowedHosts = lib.concatStringsSep "," ([
          cfg.domain
          (ip "home")
          "localhost"
          "127.0.0.1:${toString cfg.port}"
        ]
        ++ cfg.extraAllowedHosts);

      settings = {
        title = cfg.title;
        headerStyle = "boxed";
        layout = {
          "Media" = {
            style = "row";
            columns = 4;
          };
          "Downloads" = {
            style = "row";
            columns = 2;
          };
          "AI" = {
            style = "row";
            columns = 2;
          };
          "Infrastructure" = {
            style = "row";
            columns = 2;
          };
          "Proxmox" = {
            style = "row";
            columns = 3;
          };
        };
      };

      # Status dots only -- no API keys anywhere, so there is nothing here to
      # rotate and nothing that breaks when a service changes its API.
      services = [
        {
          "Media" = [
            (entry {
              name = "Jellyfin";
              host = "media";
              port = 8096;
              description = "Films, shows and music";
              icon = "jellyfin.png";
            })
            (entry {
              name = "Jellyseerr";
              host = "media";
              port = 5055;
              description = "Request something new";
              icon = "jellyseerr.png";
            })
            (entry {
              name = "Sonarr";
              host = "media";
              port = 8989;
              description = "TV series";
              icon = "sonarr.png";
            })
            (entry {
              name = "Radarr";
              host = "media";
              port = 7878;
              description = "Films";
              icon = "radarr.png";
            })
            (entry {
              name = "Prowlarr";
              host = "media";
              port = 9696;
              description = "Indexers";
              icon = "prowlarr.png";
            })
            (entry {
              name = "Bazarr";
              host = "media";
              port = 6767;
              description = "Subtitles";
              icon = "bazarr.png";
            })
          ];
        }
        {
          "Downloads" = [
            (entry {
              name = "qBittorrent";
              host = "media";
              port = 5252;
              description = "Download client, confined to Mullvad";
              icon = "qbittorrent.png";
            })
          ];
        }
        {
          "AI" = [
            (entry {
              name = "Open WebUI";
              host = "ollama";
              port = 3000;
              description = "Chat against the local models";
              icon = "open-webui.png";
            })
            (entry {
              name = "Ollama API";
              host = "ollama";
              port = 11434;
              description = "Model API on the RTX 4000";
              icon = "ollama.png";
            })
          ];
        }
        {
          "Infrastructure" = [
            (entry {
              name = "Pi-hole";
              host = "dns";
              port = 80;
              path = "/admin";
              description = "DNS and ad blocking";
              icon = "pi-hole.png";
            })
            (entry {
              name = "Forgejo";
              host = "git";
              port = 80;
              description = "Git forge";
              icon = "forgejo.png";
            })
          ];
        }
        {
          "Proxmox" = [
            (entry {
              name = "dell";
              host = "dell";
              port = 8006;
              scheme = "https";
              description = "Xeon W-2245, 96GB, RTX 4000";
              icon = "proxmox.png";
            })
            (entry {
              name = "hp16";
              host = "hp16";
              port = 8006;
              scheme = "https";
              description = "i7, 16GB";
              icon = "proxmox.png";
            })
            (entry {
              name = "hp32";
              host = "hp32";
              port = 8006;
              scheme = "https";
              description = "i7, 32GB";
              icon = "proxmox.png";
            })
          ];
        }
      ];
    };

    # ========================================================================
    # REVERSE PROXY AND FIREWALL
    # ========================================================================

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedGzipSettings = true;

      # default so the dashboard also answers when reached by bare IP, which
      # is what you fall back to when DNS is the thing that broke.
      virtualHosts.${cfg.domain} = {
        default = true;
        locations."/".proxyPass = "http://127.0.0.1:${toString cfg.port}";
      };
    };

    networking.firewall.allowedTCPPorts = [80];
  };
}
