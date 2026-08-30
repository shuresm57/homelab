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

# Stage 1 — hp16: DNS and Forgejo — **built**

Both VMs are running. `dns` (`.64`) serves Pi-hole natively; `git` (`.61`) serves Forgejo behind
nginx. The configuration **is** the documentation now — read the files rather than a guide that
can drift from them:

```
terraform/infra/        providers.tf  variables.tf  main.tf  terraform.tfvars (gitignored)
terraform/modules/proxmox-vm/
nix/flake.nix           nixpkgs pinned to nixos-26.05
nix/modules/base.nix    cloud-init, ssh, disk layout, bootloader
nix/hosts/dns.nix       services.pihole-ftl + services.pihole-web
nix/hosts/git.nix       services.forgejo + nginx
```

Operational commands live in `docs/commands.md` (gitignored, local only).

## What this guide got wrong

Recorded because each one cost real time, and Stages 2 and 3 repeat the same patterns.

**Pi-hole does not need Docker.** This guide ran it as a container because `services.pihole` does
not exist in nixpkgs **25.05**. It does exist in **25.11+** as `services.pihole-ftl` +
`services.pihole-web`. The container version caused four separate failures — port 53 contention,
an image that could not be pulled without DNS, queries silently dropped by dnsmasq's `LOCAL` mode
behind Docker's bridge NAT, and no declarative password. Bumping the flake to `nixos-26.05` and
using the native module removed all four. **When something has no NixOS module, check whether your
pin is simply old before reaching for a container.**

**Never disable `systemd-resolved` to free port 53.** Use:

```nix
services.resolved.settings.Resolve.DNSStubListener = false;
```

`services.resolved.enable = false` leaves the machine with *no resolver at all*, which means it
cannot fetch the closure that would fix it. That is an unrecoverable deadlock without an
out-of-band edit to `/etc/resolv.conf`. Also set `networking.nameservers` to the router: a DNS
server that resolves through itself cannot bootstrap.

**The Terraform provider needs an SSH username.** Token auth carries no SSH identity, so
`ssh { agent = true; }` alone connects as `""` and fails at disk creation:

```hcl
ssh { agent = true; username = "root"; }
```

**A qcow2 goes in the `import` datastore, not `iso`.** PVE's `$ISO_EXT_RE` accepts only `.iso` and
`.img`; a `.qcow2` under `local:iso/` fails with *"unable to parse directory volume name"* and is
invisible to `pvesm list`. Use `local:import/nixos-base.qcow2`.

**Two more that only bite from macOS:**

- `nixos-rebuild` needs `--no-reexec`, or it tries to build an `x86_64-linux` copy of itself
  locally and dies on platform mismatch. It also needs `--build-host`, since macOS cannot build
  Linux derivations. Evaluation is platform-independent and works fine locally.
- `nixos-generate -c` resolves `<nixpkgs>` through `NIX_PATH`, the pre-flakes mechanism. On a
  flakes-only install that is empty. Pin it to the rev from `flake.lock` so the image matches
  the flake.

## What the code cannot tell you

**Provider aliases cannot be dynamic.** Terraform resolves providers before evaluating `for_each`,
so `provider = proxmox[each.value.host]` is impossible. That single constraint is why `main.tf`
has one `module` block per host, and why the VM map is nested by host rather than flat and
filtered — the nesting mirrors a limitation you cannot design around.

**`for_each` over a map, never `count`.** With `count`, resources are addressed by index, so
deleting one VM renumbers the rest and destroys machines you did not touch. `for_each` gives you
`module.hp16["dns"]`, stable forever.

**The image and the flake are two separate evaluations.** `nixos-generators` supplies
`fileSystems` and a bootloader while building the image; your flake does not import that module,
so `base.nix` must declare them itself or `nixos-rebuild` fails with *"The `fileSystems` option
does not specify your root file system."* Match the bootloader to the firmware — the Terraform
module sets `bios = "ovmf"`, so it is systemd-boot and an ESP at `/boot`, not BIOS GRUB.

**`system.stateVersion` is not a version to bump.** It records which release's *stateful* defaults
this machine expects, so upgrading nixpkgs cannot silently migrate data underneath you. It stayed
`"25.05"` through the jump to 26.05, correctly.

**Generated config beats copied config.** `dns.nix` holds one `records` attrset and derives
Pi-hole's host list from it:

```nix
hosts = lib.mapAttrsToList (name: ip: "${ip} ${name}") records;
```

Addresses stop being a hand-copied list that drifts from `network-inventory.md`.

**Secrets have a declarative path, usually.** The Pi-hole admin password is a BALLOON-SHA256 hash
in `dns.nix`, generated without ever writing to disk:

```bash
FTLCONF_webserver_api_password="$PW" pihole-FTL --config webserver.api.pwhash
```

The module sets `misc.readOnly = true` so runtime changes cannot silently diverge from config —
which is why the password could not be set with `pihole setpassword`.

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
