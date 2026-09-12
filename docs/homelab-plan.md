# Homelab build guide

Proxmox + Terraform + NixOS, with Docker for the few services that ship as containers.
Kubernetes is deferred; the last section describes how to add it without redoing any of this.

**How to read this.** Every section is *what you are doing* → *the code* → **What to notice**,
which is the part that teaches. Read the "What to notice" blocks even when the code looks obvious;
that is where the reasoning lives.

**Every option name should be checked against `search.nixos.org/options`** before you use it.
NixOS module options move between releases, and this guide is written against **nixpkgs 26.05**,
which is what `nix/flake.nix` pins. Where I am less certain, the text says so. Options belonging
to a third-party module get checked against that module's own docs instead — for Nixarr, that is
`nixarr.com/nixos-options`.

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
    ├─ dns   NixOS   2 GB   .64   services.pihole-ftl + pihole-web
    └─ git   NixOS   4 GB   .61   services.forgejo + nginx

dell — 96 GB, RTX 4000, 12 TB                   STAGE 2
    ├─ ollama  NixOS   48 GB   .67   native ollama + open-webui (Docker)
    └─ media   NixOS   10 GB   .66   nixarr stack, ZFS RAIDZ1 over the HBA

hp32 — 32 GB                                    STAGE 3
    ├─ monitoring  NixOS   8 GB   .68   grafana + prometheus
    └─ backup      NixOS   4 GB   .69   restic target + NFS
```

| | | | |
|---|---|---|---|
| `.60` `.62` `.63` | reserved — future k8s | `.66` | media |
| `.61` | git | `.67` | ollama |
| `.64` | dns *(unchanged)* | `.68` | monitoring |
| `.65` | free — was truenas | `.69` | backup |

hp16 uses 6 of 16 GB, hp32 12 of 32. That headroom is where Kubernetes goes later.

---

# Stage 1 — hp16: DNS and Forgejo — **built**

Done, and moved out of this guide: `dns` (`.64`) and `git` (`.61`) are running, and the record
of how — plus every lesson the first build taught — now lives in
[guide/completed.md](guide/completed.md). Nothing in this section is left to do.

# Stage 2 — dell

## 2.1 Retire TrueNAS before any Dell apply

TrueNAS is out of the design. The pool it was going to serve over NFS is built directly on the
media VM instead (§2.4), so the `truenas` guest is deleted and its HBA moves to `media`.

```hcl
# terraform/hosts/dell/vms.tf -- delete module "truenas" entirely,
# and move this line onto the new media VM:
  hostpci_mappings = ["truenas-it"]

# terraform/hosts/dell/images.tf -- delete, nothing references it any more:
  resource "proxmox_download_file" "truenas_iso" { ... }
```

> **Why the order matters.** Do not `apply` this root while `module "truenas"` still exists.
> `terraform plan` currently wants to re-attach the install ISO, and because `boot_order` puts
> the CD first, the next boot of that VM lands in the **TrueNAS installer** rather than the
> installed system. Deleting the module removes the question; repairing it, as an earlier
> version of this guide suggested, is wasted work on a machine you are about to destroy.
> Full diagnosis: `docs/guide/completed.md` → "Known drift".
>
> **Back up the state file first.** The Dell's guests live in
> `terraform/hosts/dell/terraform.tfstate`, separate from `infra/` — see §2.2.
>
> **The mapping name stays `truenas-it`.** It is a Proxmox resource mapping bound to the HBA,
> not to a VM; renaming it is cosmetic and costs another apply. `completed.md` lesson 1 explains
> why a named mapping is what makes passthrough work under token auth.

Also flip `dns_servers` in `terraform/modules/proxmox-vm/variables.tf` to
`["192.168.0.64", "192.168.0.1"]` — it is currently router-first.

## 2.2 Move the Dell into `infra/`

The Dell's `ollama` is live, in a *different* state file. Do §2.1 first, so that `truenas`
is already gone and there is one guest to move rather than two.

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
> - Add `ollama` to `locals.vms` with `host = "dell"` and add a `module "dell"` block mirroring
>   `module "hp16"` but with `providers = { proxmox = proxmox.dell }`. The exact target address
>   in the command above is whatever that module block produces — `terraform state list` in
>   each root tells you the real names.
> - **`media` is declared here, not migrated.** It has no existing state, so it goes straight
>   into `locals.vms.dell` as a new entry — `vm_id` 701 or 703 (the Dell uses the 700 block;
>   700 and 702 are taken), 10240 MB, `ip = "192.168.0.66/24"`, plus
>   `hostpci_mappings = ["truenas-it"]` from §2.1. Note it needs the NixOS base qcow2, which
>   currently exists only on hp16 — copy it to the Dell's `local:import/` first.
> - **Done when `terraform plan` in `infra/` says "No changes"** against the running machines.

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

## 2.4 `media` — Nixarr on local ZFS

One VM at `.66` runs the whole media stack and owns the storage. [Nixarr](https://nixarr.com)
supplies the services; ZFS on the passed-through HBA supplies the disk. There is no NAS in the
middle any more.

Nixarr is a third-party flake, so it arrives as an input rather than from nixpkgs:

```nix
# nix/flake.nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  nixarr.url  = "github:nix-media-server/nixarr";
  nixarr.inputs.nixpkgs.follows = "nixpkgs";
};

# mkHost gains specialArgs, so a module can reach the flake's inputs
mkHost = name: nixpkgs.lib.nixosSystem {
  inherit system;
  specialArgs = { inherit inputs; };
  modules = [ ./modules ./hosts/${name}.nix ];
};
```

Two new modules, in the same shape as `forgejo.nix` and `pihole.nix`. Storage is its own module
because the planned `backup` host (§3.1) will want it too:

```nix
# nix/modules/zfs.nix -- homelab.storage.zfs.{enable,hostId,pools,autoScrub,scrubInterval}
#   sets boot.supportedFilesystems = [ "zfs" ], networking.hostId, services.zfs.autoScrub

# nix/modules/media.nix
{ config, lib, pkgs, inputs, ... }:
{
  imports = [ inputs.nixarr.nixosModules.default ];
  # options.homelab.services.media = { ... };  then, under mkIf cfg.enable:
}
```

What `homelab.services.media` should produce:

```nix
nixarr = {
  enable   = true;
  mediaDir = "/data/media";
  stateDir = "/data/.state/nixarr";

  vpn = {
    enable = true;
    # ProtonVPN wg-quick file. Never in this repo.
    wgConf = "/data/.secret/vpn/wg.conf";
  };

  jellyfin.enable = true;   # 8096, read-only option
  sonarr.enable   = true;   # 8989
  radarr.enable   = true;   # 7878
  prowlarr.enable = true;   # 9696
  bazarr.enable   = true;   # 6767
  seerr.enable    = true;   # 5055  -- Jellyseerr, but the option is `seerr`

  qbittorrent = {
    enable     = true;
    vpn.enable = true;
    peerPort   = 6881;      # webuiPort defaults to 5252
  };
};
```

And the host file stays thin, as the others do:

```nix
# nix/hosts/media.nix
{ ... }:
{
  networking.hostName = "media";

  homelab.storage.zfs = {
    enable = true;
    hostId = "<8 hex chars>";     # head -c4 /dev/urandom | od -A none -t x4
    pools  = [ "tank" ];
  };

  fileSystems."/data/media"  = { device = "tank/media"; fsType = "zfs"; };
  fileSystems."/data/.state" = { device = "tank/state"; fsType = "zfs"; };

  homelab.services.media.enable = true;
}
```

The pool itself is created once, by hand, on the VM — NixOS imports and mounts pools, it does not
create them:

```bash
zpool create -o ashift=12 \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -m none tank raidz1 \
  /dev/disk/by-id/wwn-... /dev/disk/by-id/wwn-... \
  /dev/disk/by-id/wwn-... /dev/disk/by-id/wwn-...

zfs create -o mountpoint=legacy tank/media
zfs create -o mountpoint=legacy tank/state
```

> **What to notice**
>
> - **`mountpoint=legacy` plus `fileSystems`, not `boot.zfs.extraPools`.** Legacy mounts join
>   `local-fs.target`, and `systemd-tmpfiles-setup` runs after that target, so Nixarr's directory
>   creation cannot race the pool import. With `extraPools` there is no such ordering: the
>   tmpfiles rules can fire first and scatter directories onto the root filesystem underneath an
>   unmounted mountpoint, where they are invisible the moment the pool mounts over them. This is
>   the same failure the Forgejo dump has `RequiresMountsFor` for.
> - **One dataset for media, not two.** Nixarr puts `library/` and `torrents/` *inside*
>   `mediaDir`. ZFS datasets are separate filesystems, so a tidy-looking `tank/media` +
>   `tank/downloads` split would silently turn every import from a hardlink into a full copy of
>   the file.
> - **`by-id` paths, never `/dev/sdX`.** HBA enumeration order is not stable across boots.
> - **`xattr=sa` and `acltype=posixacl`** because Nixarr manages ownership and permissions across
>   the whole media tree. Note Nixarr's own constraint too: every parent directory of `mediaDir`
>   and `stateDir` must be root-owned, which is why they sit under `/data` and not under a home
>   directory.
> - **RAIDZ1 over four drives** gives three drives of usable capacity and survives one failure.
> - **`networking.hostId` is mandatory for ZFS.** It records which machine last imported the
>   pool, and is what stops two hosts importing it at once. Generate it once and never change it.
> - **The `*arr`s deliberately stay off the VPN.** Nixarr's own docs warn that routing them
>   through it causes indexer rate limiting. Only the download client is confined.
> - **An assertion, not a comment, keeps the client behind the VPN:**
>
>   ```nix
>   assertions = [{
>     assertion = cfg.qbittorrent.enable -> cfg.vpn.enable;
>     message = ''
>       homelab.services.media.qbittorrent.enable requires vpn.enable.
>       A torrent client must not run on the bare WAN address.
>     '';
>   }];
>   ```
>
>   Nixarr already enforces `nixarr.qbittorrent.vpn.enable` → `nixarr.vpn.enable`. This second
>   assertion is the one that stops the client coming up with the VPN switched off entirely,
>   which is the mistake that actually costs you something.
> - **`openFirewall` is not how you reach a VPN-confined service.** qBittorrent lives in the VPN
>   network namespace; LAN access to its WebUI comes from `nixarr.vpn.exposeOnLAN` (default
>   `true`) and `nixarr.vpn.accessibleFrom`, whose defaults already cover `192.168.0.0/24`.
> - **The WebUI on 5252 is `qui`, not qBittorrent's own interface.** `qbittorrent.qui.enable`
>   defaults to `true` and proxies to the native UI on an internal `8085`. Surprising once.
> - **Wiring qBittorrent into Sonarr and Radarr declaratively takes the generic list.** There is a
>   `settings-sync.transmission.enable` shortcut and no qBittorrent equivalent, so use
>   `settings-sync.downloadClients` with `implementation = "QBittorrent"`. Get the field names
>   from `nixarr show-sonarr-schemas download_client` on the host rather than guessing.
> - **Nixarr's own flake tracks `nixos-25.11` while this repo is on `nixos-26.05`.** As a NixOS
>   module it builds against *our* `pkgs`, so the `follows` line only avoids a second nixpkgs in
>   the lock file. If the combination refuses to evaluate, drop that line first — it is the
>   cheapest thing to try.
> - **`imports` cannot be conditional.** Putting `media.nix` in `modules/default.nix` means `dns`
>   and `git` evaluate Nixarr's option tree as well. Check it with the `drvPath` comparison from
>   `completed.md`; if either hash moves, list `media.nix` under the `media` host in `flake.nix`
>   instead of in the shared import list.

### ProtonVPN, and the port you do not get

Nixarr wants one thing from the provider: a `wg-quick` configuration file. Download it from
Proton's account pages, from a **P2P-enabled** server — Proton only permits torrent traffic on
some of them, and the rest simply drop it. The file contains a private key, so it belongs at
`/data/.secret/vpn/wg.conf` on the host and never in this repository. It is the first real
customer for the sops-nix migration in §2.6.

The part worth knowing before you are confused by it: **Proton's port forwarding is NAT-PMP, and
Nixarr cannot drive it.** The module's only port-forwarding controls are the static
`nixarr.vpn.openTcpPorts` / `openUdpPorts` and a router-side `util-nixarr.upnp` — there is no
NAT-PMP anywhere in it. So qBittorrent runs outbound-only: downloading works, but it is slower to
find peers and it cannot meaningfully seed, because nothing on the internet can open a connection
to it. Getting a real forwarded port means running `natpmpc` on a renewal loop and feeding the
port it returns back into qBittorrent on every renewal, which is a separate piece of machinery
and not something this module does. Decide that you do not need it before assuming it works.

`nixarr.vpn.vpnTestService.enable` exists precisely to check the tunnel and any forwarded port
before trusting it with traffic. Use it once.

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
> - **The ProtonVPN `wg.conf` from §2.4 is the first secret that genuinely needs this.** It sits
>   at `/data/.secret/vpn/wg.conf`, placed by hand, outside the repo — which means it is not
>   reproducible and not backed up with everything else. `nixarr.vpn.wgConf` takes a path, so it
>   can point at `config.sops.secrets.wg-conf.path` the moment this lands.

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

**Stage 1** — done; see [guide/completed.md](guide/completed.md).

**Stage 2**
1. `terraform plan` reports "No changes" after the state move
2. `nvidia-smi` inside the ollama VM sees the RTX 4000; `ollama list` shows declared models
3. `lsblk` on `media` shows all four HBA disks, and `zpool status tank` reports `ONLINE`
4. `findmnt /data/media /data/.state` says `zfs` for both — if not, Nixarr has written into the
   root filesystem underneath a mountpoint and those directories need moving before use
5. Every web UI answers: jellyfin 8096, sonarr 8989, radarr 7878, prowlarr 9696, bazarr 6767,
   seerr 5055, qbittorrent 5252
6. `nixarr.vpn.vpnTestService` confirms the tunnel, **before** qBittorrent is given anything to do
7. Enabling `qbittorrent` with `vpn.enable = false` fails evaluation with the assertion message,
   not at runtime

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
| Nixarr | `nixarr.com/nixos-options` for every option; `nixarr.com/wiki` for worked examples |
| ZFS | `openzfs.github.io/openzfs-docs` → *Basic Concepts*, then the NixOS manual on `boot.zfs` |

Already in this repo: `docs/network-inventory.md` owns every address, and
`docs/guide/completed.md` records what shipped plus the fifteen lessons the first two builds
taught — read its **"Known drift"** section before your first Dell `apply`.
