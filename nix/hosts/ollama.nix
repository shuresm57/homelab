# nix/hosts/ollama.nix
{
  config,
  lib,
  pkgs,
  ...
}: {
  networking.hostName = "ollama";

  # The NVIDIA driver is unfree. Declared here rather than relying on an
  # --impure NIXPKGS_ALLOW_UNFREE, so nixos-rebuild works unattended.
  nixpkgs.config.allowUnfree = true;

  # ==========================================================================
  # GPU -- RTX 4000 passed through as the 'ollama-gpu' Proxmox resource mapping
  # ==========================================================================
  # Turing, so the proprietary driver rather than the open kernel modules.
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = ["nvidia"];

  hardware.nvidia = {
    open = false;
    nvidiaSettings = false; # headless
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # Keeps the driver initialised between jobs, so the idle card drops to P8
    # (~10W) instead of being torn down and re-initialised into a higher state.
    nvidiaPersistenced = true;
  };

  # ==========================================================================
  # OLLAMA -- native, so it reaches the GPU without the container toolkit
  # ==========================================================================
  services.ollama = {
    enable = true;
    # 26.05 removed services.ollama.acceleration; the CUDA build is a package
    # choice now.
    package = pkgs.ollama-cuda;
    host = "0.0.0.0"; # open-webui reaches it from a container
    loadModels = ["deepseek-coder:33b" "deepseek-coder-v2:16b"];
  };

  services.ollama.environmentVariables = {
    OLLAMA_FLASH_ATTENTION = "1";
    OLLAMA_KV_CACHE_TYPE = "q8_0";

    # A resident model keeps the card out of its lowest P-state. Five minutes
    # covers a working session; the reload after that is a few seconds.
    OLLAMA_KEEP_ALIVE = "5m";

    OLLAMA_MAX_LOADED_MODELS = "2";
  };

  # ==========================================================================
  # OPEN-WEBUI -- upstream ships it only as a container
  # ==========================================================================
  # docker.nix is already imported by modules/default.nix, but everything in it
  # is gated behind this option, including oci-containers.backend.
  homelab.docker.enable = true;

  virtualisation.oci-containers.containers.open-webui = {
    image = "ghcr.io/open-webui/open-webui:main";
    ports = ["3000:8080"];
    volumes = ["/var/lib/open-webui:/app/backend/data"];

    # host.docker.internal + --add-host=...:host-gateway is how a container
    # reaches a service running natively on its host.
    environment = {
      OLLAMA_BASE_URL = "http://host.docker.internal:11434";
    };
    extraOptions = ["--add-host=host.docker.internal:host-gateway"];

    # TODO: WEBUI_SECRET_KEY via sops-nix. Unset means open-webui generates one
    # per start, so sessions drop on restart.
  };

  networking.firewall.allowedTCPPorts = [3000 11434];
}
