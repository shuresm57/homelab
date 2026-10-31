# nix/hosts/home.nix
{...}: {
  networking.hostName = "home";

  homelab.services.dashboard = {
    enable = true;
    title = "homelab";
  };
}
