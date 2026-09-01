[working-directory: 'nix']
rebuild host:
  #!/usr/bin/env bash
  set -euo pipefail
  case {{host}} in
    git) ip=192.168.0.61 ;;
    web) ip=192.168.0.62 ;;
    db)  ip=192.168.0.63 ;;
    *) echo "unknown host: {{host}}" >&2; exit 1 ;;
  esac
  nix run nixpkgs#nixos-rebuild -- switch --no-reexec --flake .#{{host}} \
      --target-host root@$ip --build-host root@$ip
