{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.tailscale;
in {
  options.homelab.tailscale = {
    enable = lib.mkEnableOption "Tailscale for remote access to the homelab";

    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["192.168.0.0/24"];
      description = "Subnets this host routes into the tailnet. Approve them in the Tailscale admin console.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      # Written by hand on the host, outside the Nix store (a reusable auth key).
      authKeyFile = "/etc/tailscale/authkey";
      useRoutingFeatures = if cfg.advertiseRoutes != [] then "server" else "client";
      extraUpFlags = lib.optional (cfg.advertiseRoutes != [])
        "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}";
    };

    networking.firewall = {
      trustedInterfaces = ["tailscale0"];
      allowedUDPPorts = [config.services.tailscale.port];
    };
  };
}
