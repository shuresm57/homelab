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
    # Ollama's own library has no Reasoning build of Ministral 3, so it is
    # pulled as GGUF from Hugging Face. nomic-embed-text serves RAG embeddings.
    loadModels = [
      "hf.co/unsloth/Ministral-3-8B-Reasoning-2512-GGUF:Q4_K_M"
      "nomic-embed-text"
    ];
  };

  services.ollama.environmentVariables = {
    OLLAMA_FLASH_ATTENTION = "1";
    OLLAMA_KV_CACHE_TYPE = "q8_0";

    # A resident model keeps the card out of its lowest P-state. Five minutes
    # covers a working session; the reload after that is a few seconds.
    OLLAMA_KEEP_ALIVE = "5m";

    OLLAMA_MAX_LOADED_MODELS = "2";

    # Ollama's default of 4096 tokens is too small once open-webui adds its
    # system prompt, uploaded documents and search results.
    OLLAMA_CONTEXT_LENGTH = "16384";
  };

  # The Hugging Face pull is named after its repo. Give it a short name, which
  # is what open-webui lists. ollama cp is a metadata copy, no extra disk.
  systemd.services.ollama-model-alias = {
    description = "Short names for Hugging Face models";
    # ollama-model-loader counts as started before its pulls finish, so this
    # pulls the model itself (a no-op once it is there) before the copy.
    after = ["ollama.service"];
    requires = ["ollama.service"];
    wantedBy = ["multi-user.target"];
    environment = {
      OLLAMA_HOST = "127.0.0.1:11434";
      # The CLI panics without it, even though it only talks to the server.
      HOME = "/var/lib/ollama";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = let
      ollama = lib.getExe config.services.ollama.package;
      src = "hf.co/unsloth/Ministral-3-8B-Reasoning-2512-GGUF:Q4_K_M";
    in ''
      ${ollama} pull ${src}
      ${ollama} cp ${src} ministral-3:8b-reasoning
    '';
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
      WEBUI_URL = "http://ollama.home.arpa:3000";

      # --- SSO via Keycloak (realm homelab on the git VM) ---
      ENABLE_OAUTH_SIGNUP = "true";
      OAUTH_MERGE_ACCOUNTS_BY_EMAIL = "true";
      OAUTH_PROVIDER_NAME = "Keycloak";
      OAUTH_CLIENT_ID = "open-webui";
      OPENID_PROVIDER_URL = "https://auth.vstov.dk/realms/homelab/.well-known/openid-configuration";
      OAUTH_SCOPES = "openid email profile";
      ENABLE_OAUTH_ROLE_MANAGEMENT = "true";
      OAUTH_ROLES_CLAIM = "groups";
      OAUTH_ADMIN_ROLES = "openwebui-admins";
      OAUTH_ALLOWED_ROLES = "openwebui-users,openwebui-admins";
      # Second deploy, once a Keycloak login works:
      # ENABLE_LOGIN_FORM = "false";

      # --- Document upload: embeddings on the GPU through Ollama ---
      RAG_EMBEDDING_ENGINE = "ollama";
      RAG_EMBEDDING_MODEL = "nomic-embed-text";
      RAG_OLLAMA_BASE_URL = "http://host.docker.internal:11434";

      # --- Web search through the local SearXNG ---
      ENABLE_WEB_SEARCH = "true";
      WEB_SEARCH_ENGINE = "searxng";
      SEARXNG_QUERY_URL = "http://host.docker.internal:8888/search?q=<query>";
    };

    # Written by hand on the host, like /etc/forgejo/oidc.env:
    #   OAUTH_CLIENT_SECRET=<from Keycloak>
    #   WEBUI_SECRET_KEY=<openssl rand -hex 32>
    environmentFiles = ["/etc/open-webui/oidc.env"];

    extraOptions = ["--add-host=host.docker.internal:host-gateway"];
    dependsOn = ["searxng"];
  };

  # ==========================================================================
  # SEARXNG -- metasearch backend for open-webui's web search
  # ==========================================================================
  virtualisation.oci-containers.containers.searxng = {
    image = "docker.io/searxng/searxng:latest";
    # Bound to the docker bridge, not the LAN: only the container needs it.
    ports = ["172.17.0.1:8888:8080"];
    volumes = ["/etc/searxng/settings.yml:/etc/searxng/settings.yml:ro"];
    # SEARXNG_SECRET=<openssl rand -hex 32>, written by hand.
    environmentFiles = ["/etc/searxng/env"];
  };

  environment.etc."searxng/settings.yml".text = builtins.toJSON {
    use_default_settings = true;
    server = {
      limiter = false;
      image_proxy = false;
    };
    # json is what open-webui requests; without it SearXNG answers 403.
    search.formats = ["html" "json"];
  };

  networking.firewall.allowedTCPPorts = [3000 11434];
  # Containers reach SearXNG on the bridge address.
  networking.firewall.interfaces.docker0.allowedTCPPorts = [8888];
}
