# Homelab build guide

Proxmox + Terraform + NixOS, with Docker for the few services that ship as containers.
Kubernetes is deferred; the last section describes how to add it without redoing any of this.

**How to read this.** Every section is *what you are doing* → *the code* → **What to notice**,
which is the part that teaches. Read the "What to notice" blocks even when the code looks obvious;
that is where the reasoning lives.

**Every option name should be checked against `search.nixos.org/options`** before you use it.
NixOS module options move between releases, and this guide is written against **nixpkgs 25.05**.
Where I am less certain, the text says so.

---

## The stack

| Layer | Tool | Responsible for |
|---|---|---|
| Hardware → VMs | **Proxmox**, declared in **Terraform** | Machines exist, have IPs and disks |
| VM → running services | **NixOS** | Packages, services, users, firewall, backups |
| A few services | **Docker**, declared *by* NixOS | Things upstream ships only as containers |

Docker is declared through `virtualisation.oci-containers`, so containers roll back with the rest
of the system and there is no compose file to drift. It adds no new language.

```
hp16 — 16 GB                                    STAGE 1
    ├─ dns   NixOS   2 GB   .64   Pi-hole (Docker)
    └─ git   NixOS   4 GB   .61   services.forgejo + nginx

dell — 96 GB, RTX 4000, 12 TB                   STAGE 2
    ├─ ollama    NixOS   48 GB   .67   native ollama + open-webui (Docker)
    ├─ truenas   TrueNAS 16 GB   .65   HBA passthrough
    └─ jellyfin  NixOS    8 GB   .66

hp32 — 32 GB                                    STAGE 3
    ├─ monitoring  NixOS   8 GB   .68   grafana + prometheus
    └─ backup      NixOS   4 GB   .69   restic target + NFS
```

| | | | |
|---|---|---|---|
| `.60` `.62` `.63` | reserved — future k8s | `.66` | jellyfin |
| `.61` | git | `.67` | ollama |
| `.64` | dns *(unchanged)* | `.68` | monitoring |
| `.65` | truenas | `.69` | backup |

hp16 uses 6 of 16 GB, hp32 12 of 32. That headroom is where Kubernetes goes later.

---

# Stage 1 — hp16: DNS and Forgejo

## 1.1 Terraform: one root for every machine

```
terraform/
  infra/       providers.tf  variables.tf  images.tf  main.tf  terraform.tfvars
  modules/proxmox-vm/        # unchanged — you already wrote this
```

### `terraform/infra/providers.tf`

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}

# One provider block per Proxmox host. They cannot be generated from a variable —
# see "What to notice" below.
provider "proxmox" {
  alias     = "hp16"
  endpoint  = var.pve_hosts.hp16.endpoint
  api_token = var.pve_hosts.hp16.api_token
  insecure  = true
  ssh { agent = true }
}

provider "proxmox" {
  alias     = "dell"
  endpoint  = var.pve_hosts.dell.endpoint
  api_token = var.pve_hosts.dell.api_token
  insecure  = true
  ssh { agent = true }
}

provider "proxmox" {
  alias     = "hp32"
  endpoint  = var.pve_hosts.hp32.endpoint
  api_token = var.pve_hosts.hp32.api_token
  insecure  = true
  ssh { agent = true }
}
```

> **What to notice**
>
> - **`alias`** is what lets one root module talk to three different Proxmox servers. Without it
>   you would need three root modules — which is exactly the duplication you have today.
> - **`ssh { agent = true }` is not optional.** The bpg provider uploads disk images over SCP, not
>   through the API, so the key for your Proxmox SSH user must be in a running ssh-agent when you
>   `apply`. `docs/guide/completed.md` records this the hard way.
> - **`insecure = true`** accepts Proxmox's self-signed certificate. Fine on your LAN; it is the
>   line you would remove if these were public.
> - **You cannot write `provider = proxmox[each.value.host]`.** Terraform resolves providers before
>   it evaluates `for_each`, so aliases can never come from a variable. This is the single most
>   common wall people hit with this pattern, and it is why 1.1 has one module block per host
>   rather than one clever one.

### `terraform/infra/variables.tf`

```hcl
variable "pve_hosts" {
  description = "One entry per Proxmox host."
  type = map(object({
    endpoint  = string
    node_name = string
    datastore = string
    api_token = string
  }))
  sensitive = true
}

variable "ssh_public_key" {
  type = string
}

variable "console_password" {
  description = "Fallback password for the Proxmox web console. SSH is key-only."
  type        = string
  sensitive   = true
}

variable "nixos_image_file_id" {
  description = "Proxmox file ID of the NixOS base image built in 1.2, e.g. local:iso/nixos.qcow2"
  type        = string
}
```

> **What to notice**
>
> - **`map(object({...}))`** gives you type-checking on a nested structure. Get a key wrong and
>   Terraform tells you at `plan`, not at `apply`.
> - **`sensitive = true`** keeps the value out of plan output and logs. It does *not* encrypt
>   anything — the tfvars file on disk is still plaintext, which is why it is gitignored.
> - Replacing the old `dell_endpoint` / `dell_node_name` / `dell_datastore` variables with one map
>   is what finishes the rename the previous refactor started.

### `terraform/infra/main.tf`

```hcl
locals {
  # Every VM in the lab, grouped by the machine it runs on.
  # Adding a VM is a new entry here and nothing else.
  vms = {
    hp16 = {
      dns = {
        vm_id        = 640
        cores        = 1
        memory_mb    = 2048
        disk_size_gb = 16
        ip           = "192.168.0.64/24"
      }
      git = {
        vm_id        = 641
        cores        = 2
        memory_mb    = 4096
        disk_size_gb = 40
        ip           = "192.168.0.61/24"
      }
    }

    dell = {}   # filled in Stage 2
    hp32 = {}   # filled in Stage 3
  }
}

module "hp16" {
  source   = "../modules/proxmox-vm"
  for_each = local.vms.hp16

  providers = { proxmox = proxmox.hp16 }

  name          = each.key
  vm_id         = each.value.vm_id
  node_name     = var.pve_hosts.hp16.node_name
  datastore     = var.pve_hosts.hp16.datastore
  cores         = each.value.cores
  memory_mb     = each.value.memory_mb
  disk_size_gb  = each.value.disk_size_gb
  disk_image_id = var.nixos_image_file_id
  ipv4_address  = each.value.ip
  dns_servers   = ["192.168.0.64", "192.168.0.1"]

  user_account = {
    username = "nixos"
    password = var.console_password
    keys     = [var.ssh_public_key]
  }
}
```

> **What to notice**
>
> - **`for_each` over a map, not `count`.** With `count`, resources are addressed by index —
>   delete the first VM and Terraform renumbers everything and destroys machines you did not
>   touch. With `for_each` the address is `module.hp16["dns"]`, stable forever.
> - **`providers = { proxmox = proxmox.hp16 }`** is how a module receives an alias. Your
>   `modules/proxmox-vm` uses the default provider internally, so this substitution just works
>   with **no change to the module**.
> - **`each.key` is the VM name.** The map key does double duty as identity, which is why the keys
>   are `dns` and `git` rather than `vm1`.
> - **`dns_servers` puts Pi-hole first.** The module's default has the router first, which silently
>   bypasses filtering. Fix that default in `modules/proxmox-vm/variables.tf` too.
> - **The map is nested by host, and that is deliberate.** Since providers force one module block
>   per host, the data may as well be grouped the same way — `local.vms.hp16` needs no filtering.
>   The obvious alternative is a *flat* map where each VM carries `host = "hp16"`, then three
>   filtered locals:
>
>   ```hcl
>   hp16_vms = { for k, v in local.vms : k => v if v.host == "hp16" }
>   ```
>
>   That is a **for expression**: `{ }` builds a map, `for k, v in local.vms` iterates it,
>   `k => v` keeps each entry unchanged, and `if` filters. Worth being able to read — you will meet
>   it constantly — but here it derives grouping you could just write down. The nested version has
>   no `for`, no `if`, and no `host` attribute to keep in sync.
>
>   The one thing flat gives you: duplicate VM names become impossible, and a one-line view of
>   every VM. You can still get the latter from nested with
>   `merge(values(local.vms)...)` — where `...` expands the list into separate arguments to
>   `merge`.
> - `dell` and `hp32` are empty maps in Stage 1. `for_each = {}` creates nothing, so the module
>   blocks can exist from the start and later stages cost one entry each.

### `terraform/infra/terraform.tfvars` (gitignored)

```hcl
pve_hosts = {
  hp16 = {
    endpoint  = "https://192.168.0.125:8006"
    node_name = "hp16"
    datastore = "local-lvm"
    api_token = "terraform@pve!terraform=<uuid>"
  }
  dell = { endpoint = "https://192.168.0.254:8006", node_name = "dell", datastore = "local-lvm", api_token = "..." }
  hp32 = { endpoint = "https://192.168.0.129:8006", node_name = "hp32", datastore = "local-lvm", api_token = "..." }
}

ssh_public_key      = "ssh-ed25519 AAAA... you@example.com"
console_password    = "..."
nixos_image_file_id = "local:iso/nixos-base.qcow2"
```

> **What to notice**
>
> - **`local-lvm` for disks, `local` for files.** LVM-thin stores block devices and *cannot* hold
>   files, so images and ISOs go on `local`. The error when you get this wrong appears at apply
>   time and is not helpful. This is why `nixos_image_file_id` says `local:` and `datastore` says
>   `local-lvm`.
> - **Use a scoped token, not `root@pam`.** Create `terraform@pve` in Proxmox with only the
>   privileges it needs. Your three current tokens are full-privilege root tokens.
> - **One SSH key for the whole estate.** You currently have three.

---

## 1.2 The NixOS foundation

This is the part to solve first and the part that will take longest. Everything after it is short.

```
nix/
  flake.nix
  modules/base.nix
  modules/docker.nix
  hosts/dns.nix
  hosts/git.nix
```

### `nix/flake.nix`

```nix
{
  description = "homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";

      # Every host is base.nix plus its own file. One place to change the pattern.
      mkHost = name: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/base.nix
          ./hosts/${name}.nix
        ];
      };
    in {
      nixosConfigurations = {
        dns = mkHost "dns";
        git = mkHost "git";
      };
    };
}
```

> **What to notice**
>
> - **A flake is just an attribute set with `inputs` and `outputs`.** `inputs` are pinned in
>   `flake.lock`, which is what makes a rebuild in six months produce the same system. Commit the
>   lock file.
> - **`nixosConfigurations.<name>` is the contract.** `nixos-rebuild --flake .#dns` looks for
>   exactly that attribute. The name here must match what you pass on the command line; it does
>   *not* have to match the hostname, though keeping them the same avoids confusion.
> - **`mkHost` is an ordinary function**, `name: <body>`. Nix has no special syntax for this —
>   the reason to write it is that adding a host becomes one line instead of a copied block.
> - **`inherit system;`** is shorthand for `system = system;`. You will see it constantly.

### `nix/modules/base.nix`

```nix
{ config, pkgs, lib, ... }:
{
  # --- cloud-init: how a generic image becomes THIS machine -----------------
  # Proxmox attaches a cloud-init drive carrying the IP and SSH key that
  # Terraform set. Without this the VM boots with no address and you cannot
  # reach it to fix anything.
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # Lets Proxmox see the VM's IP and shut it down cleanly.
  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin        = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA... you@example.com"
  ];

  time.timeZone = "Europe/Copenhagen";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Keep old generations from filling the disk.
  nix.gc = {
    automatic = true;
    dates     = "weekly";
    options   = "--delete-older-than 30d";
  };

  environment.systemPackages = with pkgs; [ vim git curl ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

  # Read this as "the release whose defaults this machine expects".
  # It is NOT a version to bump on upgrade -- see below.
  system.stateVersion = "25.05";
}
```

> **What to notice**
>
> - **`{ config, pkgs, lib, ... }:` is a function.** Every NixOS module is a function from those
>   arguments to an attribute set of configuration. The `...` means "ignore any other arguments you
>   are passed", and omitting it is a common early error.
> - **`system.stateVersion` is the option people get wrong.** It does not pin your package
>   versions and you do not bump it when you upgrade. It tells NixOS which release's *stateful*
>   defaults to keep — things like default database versions — so that upgrading nixpkgs cannot
>   silently migrate data underneath you. Set it once, at install, and leave it.
> - **`services.cloud-init.network.enable` is the load-bearing line** for this whole approach, and
>   the one most likely to fight you. It hands network configuration to cloud-init instead of
>   NixOS's own settings, so do not also set `networking.interfaces.*` — they will conflict. Verify
>   the exact option shape in `search.nixos.org/options`; it has changed shape historically.
> - **`nix.gc`** matters more than it looks. Every rebuild keeps the old generation, and a 16 GB
>   root disk fills faster than you expect.

### `nix/modules/docker.nix`

```nix
{ ... }:
{
  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
}
```

> **What to notice**
>
> - Imported only by hosts that need it, so the Forgejo VM never installs Docker at all. That is
>   the point of splitting modules.
> - `oci-containers` turns each container into a **systemd unit** named `docker-<name>`, so
>   `systemctl status docker-pihole` and `journalctl -u docker-pihole` work like any other service.

### Building and deploying

```bash
# 1. Build the base image ONCE (from the nix/ directory)
nix run github:nix-community/nixos-generators -- \
  -f qcow -c ./modules/base.nix -o ./result

# 2. Upload result/*.qcow2 to Proxmox 'local' as an ISO-type file,
#    then reference it as local:iso/nixos-base.qcow2 in tfvars.

# 3. terraform apply  -> VMs exist, cloud-init gives them IPs and your key

# 4. Configure them, and every change after this:
nixos-rebuild switch --target-host root@192.168.0.64 --flake .#dns
nixos-rebuild switch --target-host root@192.168.0.61 --flake .#git

# 5. Prove rollback BEFORE you depend on it:
ssh root@192.168.0.64 nixos-rebuild --rollback switch
```

> **What to notice**
>
> - **The image is built once and cloned many times.** Per-host config never goes in the image;
>   it arrives via `nixos-rebuild`. That is why there is one image, not four.
> - **`--target-host` builds locally and copies the result over SSH.** Your Mac cannot build Linux
>   derivations natively, so either add `--build-host root@<vm>` to build on the target, or run
>   these from a Linux machine. This trips up every Mac user once — expect it.
> - **Step 5 is not optional.** Rollback is the entire safety argument for NixOS; verify it on a
>   trivial change before you are relying on it during an outage.

---

## 1.3 `dns` — Pi-hole in Docker

### `nix/hosts/dns.nix`

```nix
{ config, lib, pkgs, ... }:
let
  # Source of truth: docs/network-inventory.md
  # Generated into Pi-hole config below -- edit here, nowhere else.
  records = {
    "dns.home.arpa"        = "192.168.0.64";
    "git.home.arpa"        = "192.168.0.61";
    "truenas.home.arpa"    = "192.168.0.65";
    "jellyfin.home.arpa"   = "192.168.0.66";
    "ollama.home.arpa"     = "192.168.0.67";
    "grafana.home.arpa"    = "192.168.0.68";
    "hp16.home.arpa"       = "192.168.0.125";
    "hp32.home.arpa"       = "192.168.0.129";
    "dell.home.arpa"       = "192.168.0.254";
  };
in
{
  imports = [ ../modules/docker.nix ];

  networking.hostName = "dns";

  # systemd-resolved binds port 53. Pi-hole needs it.
  services.resolved.enable = false;

  virtualisation.oci-containers.containers.pihole = {
    image = "pihole/pihole:2025.08.0";   # pin a tag; :latest is not reproducible

    ports = [
      "53:53/tcp"
      "53:53/udp"
      "80:80/tcp"
    ];

    # Host paths, so config survives replacing the container -- and so restic
    # can back it up in Stage 3.
    volumes = [
      "/var/lib/pihole/etc-pihole:/etc/pihole"
      "/var/lib/pihole/etc-dnsmasq.d:/etc/dnsmasq.d"
    ];

    environment = {
      TZ = "Europe/Copenhagen";
      FTLCONF_dns_upstreams = "1.1.1.1;9.9.9.9";

      # The 20 records, generated from the attrset above.
      FTLCONF_dns_hosts = lib.concatStringsSep ";"
        (lib.mapAttrsToList (name: ip: "${ip} ${name}") records);
    };

    extraOptions = [ "--cap-add=NET_ADMIN" ];
  };

  networking.firewall.allowedTCPPorts = [ 53 80 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}
```

> **What to notice**
>
> - **`let ... in` binds values before the attribute set.** `records` exists only inside this file.
> - **`lib.mapAttrsToList (name: ip: ...) records`** turns `{ "git.home.arpa" = "192.168.0.61"; }`
>   into `[ "192.168.0.61 git.home.arpa" ]`, then `concatStringsSep ";"` joins them. **This is the
>   important bit:** your DNS records stop being a hand-copied list that drifts from
>   `network-inventory.md` and become generated config. It recovers most of the benefit I was
>   claiming for AdGuard, while keeping Pi-hole.
> - **Pin the image tag.** `:latest` means a `docker pull` six months from now gives you a
>   different Pi-hole, which is exactly the reproducibility you switched to Nix for.
> - **Verify the `FTLCONF_*` names against Pi-hole v6's docs.** They map to config keys — your
>   existing playbook used `pihole-FTL --config dns.hosts`, which is why the variable is
>   `FTLCONF_dns_hosts` — but confirm rather than trust this guide.
> - **The cutover is lower-risk than it looks.** Every guest has `dns_servers = [.64, .1]`, so if
>   this fails the router still answers: you lose filtering and `*.home.arpa`, not the internet.
>   The old LXC holds `.64`, so bring the new VM up elsewhere and swap, or destroy the LXC first
>   and accept a short window.

---

## 1.4 `git` — Forgejo, natively

### `nix/hosts/git.nix`

```nix
{ config, lib, pkgs, ... }:
{
  networking.hostName = "git";

  services.forgejo = {
    enable = true;
    database.type = "sqlite3";

    settings = {
      server = {
        DOMAIN     = "git.home.arpa";
        ROOT_URL   = "http://git.home.arpa/";
        HTTP_ADDR  = "127.0.0.1";   # only nginx reaches it
        HTTP_PORT  = 3000;
        SSH_PORT   = 22;
      };
      service.DISABLE_REGISTRATION = true;   # single-user lab
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedGzipSettings  = true;

    virtualHosts."git.home.arpa" = {
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 22 ];
}
```

> **What to notice**
>
> - **This is the whole service.** Compare it to a Deployment, Service, Ingress, PVC and Helm
>   values file. The NixOS module creates the user, the data directory, the systemd unit and the
>   database for you.
> - **`HTTP_ADDR = "127.0.0.1"` is deliberate.** Forgejo listens only on loopback; nothing reaches
>   it except nginx. That is why the firewall opens 80 and 22 but never 3000.
> - **`settings` maps 1:1 onto Forgejo's `app.ini`.** Anything in Forgejo's *Config Cheat Sheet*
>   goes here, in the same sections — `[server]` becomes `settings.server`.
> - **SQLite is correct at this scale.** Postgres buys you nothing for one user and adds a service
>   to back up.
> - **Data lives in `/var/lib/forgejo`** — that single path is what Stage 3's restic job protects,
>   and the only irreplaceable data in the lab.
> - Add `git.home.arpa → 192.168.0.61` to `records` in `dns.nix` and rebuild that host.

**Stage 1 is done when:** Forgejo answers at `git.home.arpa`, you can push a repo, the VM survives
a reboot with the repo intact, and `nixos-rebuild --rollback` works. Then delete
`terraform/hosts/hp-sff-16gb/`, `ansible/playbooks/{pihole,deploy-apps}.yaml`, `k8s/` and
`helm-values/`.

---

# Stage 2 — dell

## 2.1 Two fixes before any Dell apply

```hcl
# terraform/hosts/dell/vms.tf -- DELETE these two lines from module "truenas"
  iso_file_id      = proxmox_download_file.truenas_iso.id
  boot_order       = ["ide2", "scsi0"]
```

> **Why this is urgent.** `terraform plan` on the Dell currently wants to re-attach the install
> ISO. Because `boot_order` puts the CD first, the next boot of that VM lands in the **TrueNAS
> installer** rather than your installed system. With `iso_file_id` null the module's
> `dynamic "cdrom"` block emits nothing, and with `boot_order` null it boots `scsi0`.
> Full diagnosis: `docs/guide/completed.md` → "Known drift".

Also flip `dns_servers` in `terraform/modules/proxmox-vm/variables.tf` to
`["192.168.0.64", "192.168.0.1"]` — it is currently router-first.

## 2.2 Move the Dell into `infra/`

The Dell's `ollama` and `truenas` are live, in a *different* state file.

```bash
cp terraform/hosts/dell/terraform.tfstate{,.bak}
cp terraform/infra/terraform.tfstate{,.bak}

cd terraform/hosts/dell
terraform state mv -state-out=../../infra/terraform.tfstate \
  'module.ollama' 'module.hp16["placeholder"]'   # see note
```

> **What to notice**
>
> - **`moved` blocks cannot do this.** They relocate an address *within* one state file. Crossing
>   state files needs `terraform state mv -state-out=`, or `state rm` plus `import`.
> - **Back up both state files first.** This is the one operation in the guide that can lose track
>   of running machines.
> - Add `ollama` and `truenas` to `locals.vms` with `host = "dell"` and add a `module "dell"` block
>   mirroring `module "hp16"` but with `providers = { proxmox = proxmox.dell }`. The exact target
>   address in the command above is whatever that module block produces —
>   `terraform state list` in each root tells you the real names.
> - **Done when `terraform plan` in `infra/` says "No changes"** against two running machines.

## 2.3 `nix/hosts/ollama.nix`

```nix
{ config, lib, pkgs, ... }:
{
  imports = [ ../modules/docker.nix ];

  networking.hostName = "ollama";

  # --- GPU ------------------------------------------------------------------
  hardware.graphics.enable = true;          # was hardware.opengl.enable before 24.11
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open          = false;                  # RTX 4000 is Turing; use the proprietary driver
    nvidiaSettings = false;                 # headless
    package       = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # --- ollama: native, so it can reach the GPU directly ---------------------
  services.ollama = {
    enable       = true;
    acceleration = "cuda";
    host         = "0.0.0.0";               # open-webui reaches it from a container
    loadModels   = [ "deepseek-coder:33b" ];
  };

  # --- open-webui: upstream ships it as a container -------------------------
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
```

> **What to notice**
>
> - **ollama is native and open-webui is not, deliberately.** Reaching the GPU from inside a
>   container additionally requires `hardware.nvidia-container-toolkit`; the native module needs
>   none of that. They talk over HTTP, so splitting them costs nothing.
> - **`host.docker.internal` + `--add-host=...:host-gateway`** is how a container reaches a service
>   on its host. This is the pattern to remember whenever you mix native and containerised.
> - **`loadModels` replaces the imperative `ollama pull`** your playbook ran via
>   `docker_container_exec`. The model set becomes config.
> - **`WEBUI_SECRET_KEY` was referenced in your old compose file and never defined anywhere.**
>   `environmentFiles` plus sops-nix fixes that properly.
> - **Expect this to be the slowest file in the guide.** GPU passthrough at the Proxmox layer plus
>   NVIDIA drivers at the NixOS layer is two fiddly things stacked. Do the passthrough first and
>   confirm `nvidia-smi` works before touching ollama.
> - Proxmox side: create an `ollama-gpu` **resource mapping** and add it to `hostpci_mappings`.
>   `completed.md` lesson 1 explains why a mapping works with token auth where a raw PCI ID does not.

## 2.4–2.5 TrueNAS and Jellyfin

TrueNAS is unchanged; the remaining work is the ZFS pool, **blocked on a third drive** for RAIDZ1.

```nix
# nix/hosts/jellyfin.nix
{ ... }:
{
  networking.hostName = "jellyfin";

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  # Media arrives from TrueNAS once the pool exists.
  fileSystems."/media" = {
    device  = "192.168.0.65:/mnt/tank/media";
    fsType  = "nfs";
    options = [ "x-systemd.automount" "noauto" ];
  };
}
```

> **What to notice**
>
> - **`x-systemd.automount` + `noauto`** means the VM boots even when TrueNAS is down, mounting on
>   first access instead. Without it a missing NFS server blocks boot — a genuinely miserable
>   failure mode.
> - Jellyfin can run before the pool exists; only the library depends on it.

## 2.6 Ansible leaves

Migrate `ansible/group_vars/all/vault.yml` (it holds `vault_pihole_webpassword`) to **sops-nix**,
then delete `ansible/` entirely.

```nix
# in flake.nix inputs
sops-nix.url = "github:Mic92/sops-nix";

# in a host
sops.defaultSopsFile = ../secrets/secrets.yaml;
sops.age.keyFile = "/var/lib/sops-nix/key.txt";
sops.secrets.webui-secret-key = { };
```

> **What to notice**
>
> - Secrets stay **encrypted in git** and are decrypted into `/run/secrets/` at activation, owned
>   by the service that needs them. They never appear in the Nix store, which is world-readable.

---

# Stage 3 — hp32: monitoring and backups

## 3.1 `backup` — do this before monitoring

```nix
# nix/hosts/backup.nix
{ ... }:
{
  networking.hostName = "backup";

  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/restic 192.168.0.0/24(rw,sync,no_subtree_check)
    '';
  };

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
```

```nix
# in nix/hosts/git.nix -- the job that actually matters
services.restic.backups.forgejo = {
  paths        = [ "/var/lib/forgejo" ];
  repository   = "sftp:restic@192.168.0.69:/srv/restic/forgejo";
  passwordFile = config.sops.secrets.restic-password.path;
  initialize   = true;
  timerConfig.OnCalendar = "daily";
  pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
};
```

> **What to notice**
>
> - **Backups cannot live on the machine they back up.** That is the whole reason this is on hp32
>   and Forgejo is on hp16.
> - `services.restic.backups.<name>` generates a systemd timer and service. `systemctl list-timers`
>   shows it; `journalctl -u restic-backups-forgejo` shows what happened.
> - **An untested backup is not a backup.** The verification step is *restore a repo onto a scratch
>   VM*, not *the timer ran*.

## 3.2 `monitoring`

```nix
# nix/hosts/monitoring.nix
{ ... }:
{
  networking.hostName = "monitoring";

  services.prometheus = {
    enable = true;
    scrapeConfigs = [{
      job_name = "nodes";
      static_configs = [{
        targets = [
          "192.168.0.61:9100" "192.168.0.64:9100"
          "192.168.0.67:9100" "192.168.0.69:9100"
        ];
      }];
    }];
  };

  services.grafana = {
    enable = true;
    settings.server = {
      http_addr = "127.0.0.1";
      domain    = "grafana.home.arpa";
    };
  };

  services.nginx.enable = true;
  services.nginx.virtualHosts."grafana.home.arpa".locations."/".proxyPass =
    "http://127.0.0.1:3000";
}
```

Then on **every** host, in `base.nix`:

```nix
services.prometheus.exporters.node = {
  enable = true;
  openFirewall = true;
};
```

> **What to notice**
>
> - Putting the exporter in `base.nix` means every machine you ever build is monitored by default.
>   That is the payoff for having a shared module.
> - Same nginx-in-front pattern as Forgejo. Learn it once, reuse it forever.

---

# Later — adding Kubernetes

Nothing above blocks it, and the reserved capacity is deliberate: hp32 has 20 GB free, hp16 10 GB,
`.60`/`.62`/`.63` are held for nodes and `.70–.79` for a MetalLB pool.

```nix
services.k3s = {
  enable = true;
  role   = "server";
};
```

- **Move one service in, not all of them.** Forgejo is the natural first, since by then you will
  know exactly what it needs.
- **Learn the objects by hand before any tooling**: Namespace → Deployment → Service → Ingress →
  PVC, on disposable nginx. `kubernetes.io/docs/concepts` — the Concepts section, not the
  Tutorials. Helm only once you can read what it generates.
- **DNS stays out of the cluster, permanently.** A DNS server that needs a working cluster to
  resolve names is a circular dependency that ruins a weekend.

---

# Verification

**Stage 1**
1. `terraform plan` in `infra/` clean; both VMs answer SSH
2. `nixos-rebuild switch --target-host` applies a change and `--rollback` reverses it
3. `dig git.home.arpa @192.168.0.64` resolves from another machine, and a blocked domain is still
   blocked — **verify before destroying the old Pi-hole LXC**
4. Forgejo serves at `git.home.arpa`, a push succeeds, and the repo survives a VM reboot

**Stage 2**
5. `terraform plan` reports "No changes" after the state move
6. TrueNAS reboots into TrueNAS, not the installer
7. `nvidia-smi` inside the ollama VM sees the RTX 4000; `ollama list` shows declared models

**Stage 3**
8. Grafana shows `node_exporter` metrics from every host
9. **Restore a Forgejo repo from restic onto a scratch VM**

**Final:** rebuild one host from scratch and confirm the repo alone is sufficient.

---

# Where to learn each piece

| You need to | Read |
|---|---|
| **Any NixOS option** | `search.nixos.org/options` — the tool you will use most |
| Flakes, from scratch | *NixOS & Flakes Book* (`nixos-and-flakes.thiscute.world`) — the official docs assume you know why flakes exist |
| The Nix language itself | `nix.dev` → *Nix language basics*. One hour here pays for itself |
| Provider aliases in modules | Terraform docs → *Language → Modules → Providers Within Modules* |
| `for_each` semantics | Terraform docs → *Language → Meta-Arguments → for_each* |
| Moving state | Terraform docs → *CLI → Commands → state mv* |
| The Proxmox provider | `registry.terraform.io/providers/bpg/proxmox/latest/docs` |
| Building the base image | `github.com/nix-community/nixos-generators` |
| Containers under NixOS | NixOS options → `virtualisation.oci-containers`; NixOS Wiki → *Docker* |
| Pi-hole v6 config keys | Pi-hole docs → *Docker*, and the `FTLCONF_` environment variable reference |
| Forgejo's `settings` | `forgejo.org/docs` → *Administration → Config Cheat Sheet* |
| NVIDIA on NixOS | NixOS Wiki → *NVIDIA* |
| restic, including **restore** | `restic.readthedocs.io` → *Getting Started* and *Restoring* |
| Secrets | `github.com/Mic92/sops-nix` README; `getsops.io` for age keys |

Already in this repo: `docs/network-inventory.md` owns every address, and
`docs/guide/completed.md` records what shipped plus three lessons that superseded the old guide —
read its **"Known drift"** section before your first Dell `apply`.
