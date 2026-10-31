[working-directory: 'nix']
rebuild host:
  #!/usr/bin/env bash
  set -euo pipefail
  case {{host}} in
    git) ip=192.168.0.61 ;;
    dns)  ip=192.168.0.64 ;;
    home)   ip=192.168.0.65 ;;
    media)  ip=192.168.0.66 ;;
    ollama) ip=192.168.0.67 ;;
    *) echo "unknown host: {{host}}" >&2; exit 1 ;;
  esac
  nix run nixpkgs#nixos-rebuild -- switch --no-reexec --flake .#{{host}} \
      --target-host root@$ip --build-host root@$ip
