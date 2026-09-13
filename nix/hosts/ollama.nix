{ config, lib, pkgs, ... }
{
  import = [../modules/docker.nix]

  networking.hostName = "ollama";

  hardware.graphics.enable = "true";

  hardware.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
      open = false;
      nvidiaSettings = false;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };

  services.ollama = {
      enable = "true";
      acceleration = "cuda";
      host = "0.0.0.0";
      loadModels = [ "deepseek-coder:33b"];
    };

  virtualisation.oci-containers.containers.open-webui = {
      image   = "ghcr.io/open-webui/open-webui:main";
      ports   = [ "3000:8080" ];
      volumes = [ "/var/lib/open-webui:/app/backend/data" ];
      environment = {
        OLLAMA_BASE_URL = "http://host.docker.internal:11434";
      };
      environmentFiles = [ config.sops.secrets.webui-secret-key.path ];
      extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
    };

    networking.firewall.allowedTCPPorts = [ 3000 11434 ];

}
