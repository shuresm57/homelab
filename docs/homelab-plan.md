# Homelab: two layers, three machines, one at a time

## Context

The repo currently runs four Terraform roots, a Talos Kubernetes cluster split across two
machines, Ansible playbooks, Helm, raw `kubectl apply`, and hand-typed cluster commands — five
config languages for three machines. Every change is expensive, and most of the cost buys
capability that a three-machine lab does not use.

**Kubernetes is deferred, not abandoned.** It was the largest single source of complexity and the
steepest thing to learn, and nothing currently running needs it. The plan ends with a section
describing exactly how to add it later without redoing any of this work.

**What is left is two layers and three tools:**

| Layer | Tool | Responsible for |
|---|---|---|
| Hardware → VMs | **Proxmox**, declared in **Terraform** | Machines exist, have IPs and disks. Snapshots and rollback. |
| VM → running services | **NixOS** | Packages, services, users, firewall, backups. |
| A few services | **Docker**, declared *by* NixOS | The handful of things upstream ships only as containers. |

That is the whole stack. Talos, Kubernetes, Helm, MetalLB, Longhorn, Ansible and `kubectl` leave.

**Docker stays, but changes shape.** Today it is installed by an Ansible playbook with a compose
file written inline in that playbook. Instead it is declared through
`virtualisation.oci-containers` with `backend = "docker"`, so containers are part of the same
`nixos-rebuild` as everything else — same rollback, same generation history, no compose file
drifting out of sync. Note that this adds no new *language*: containers are declared in Nix.

Most services will not need it, because **NixOS has a first-class module for nearly every one** —
`services.forgejo`, `services.jellyfin`, `services.ollama`, `services.grafana`,
`services.prometheus`, `services.nfs.server`, `services.restic`. Those become a handful of lines
of Nix rather than a container, a chart and a set of manifests. Docker is for the exceptions:
**Pi-hole** and **open-webui**, both of which upstream ships as containers first.

**Order of work — one machine at a time, each independently useful:**

1. **hp16** — DNS and Forgejo. Also where you learn Terraform + NixOS end to end.
2. **dell** — ollama first, then TrueNAS, then Jellyfin.
3. **hp32** — monitoring and backups.

---

## Target architecture

```
hp16 — 16 GB                                    STAGE 1 — build this first
  Proxmox
    ├─ dns   NixOS   2 GB   .64   Pi-hole
    └─ git   NixOS   4 GB   .61   services.forgejo + nginx

dell — 96 GB, RTX 4000, 12 TB                   STAGE 2
  Proxmox
    ├─ ollama    NixOS   48 GB   .67   GPU passthrough
    ├─ truenas   TrueNAS 16 GB   .65   HBA passthrough
    └─ jellyfin  NixOS    8 GB   .66

hp32 — 32 GB                                    STAGE 3
  Proxmox
    ├─ monitoring  NixOS   8 GB   .68   grafana + prometheus
    └─ backup      NixOS   4 GB   .69   restic target + NFS
```

hp16 uses 6 of 16 GB and hp32 uses 12 of 32. That headroom is deliberate — it is where Kubernetes
goes when you come back to it.

### Addresses

Pi-hole **keeps `.64`**. Every guest points there for DNS, so not moving it removes the riskiest
step in the plan.

| | | | |
|---|---|---|---|
| `.60` `.62` `.63` | reserved — future Kubernetes nodes | `.66` | jellyfin |
| `.61` | git | `.67` | ollama |
| `.64` | dns | `.68` | monitoring |
| `.65` | truenas | `.69` | backup |

`.70–.79` stays reserved and unused; it is the MetalLB pool if Kubernetes ever arrives.

### RAM

| Host | Capacity | Allocated | Headroom |
|---|---|---|---|
| hp16 | 16 GB | 6 GB (dns 2 + git 4) | 10 GB |
| dell | 96 GB | 72 GB (ollama 48 + truenas 16 + jellyfin 8) | 24 GB |
| hp32 | 32 GB | 12 GB (monitoring 8 + backup 4) | 20 GB |

---

## Calls I made for you

My picks with reasons; override any of them.

1. **Pi-hole stays Pi-hole**, as a Docker container declared in `virtualisation.oci-containers`.
   *Correcting myself:* I argued three times for swapping it to `services.adguardhome`, on the
   grounds that Pi-hole was the only thing dragging a container runtime into the lab. **With Docker
   staying deliberately, that argument no longer holds** — Pi-hole is now free. The one reason
   left is much smaller: AdGuard's host records would be native Nix attributes generated from a
   single source, where Pi-hole's 20 records stay a hand-maintained list duplicating
   `network-inventory.md`. Worth knowing; not worth pushing.
2. **TrueNAS stays TrueNAS.** It is a third OS, which cuts against simplifying — but scrub
   scheduling, SMART reporting, snapshot retention and a UI are free there and homework in NixOS.
   The pool isn't built yet, so the door stays open.
3. **One VM per service, not one per machine.** With NixOS a VM costs one small `.nix` file, and
   separation means rebuilding Forgejo cannot take DNS down. Cheap insurance.
4. **nginx in front of Forgejo**, so `git.home.arpa` works on port 80 rather than a port number.
   `services.nginx.virtualHosts` is a few lines and teaches you the reverse-proxy pattern you will
   reuse for every later service.

---

## Vocabulary

Terms used below. Skim now, refer back later.

### Terraform

| Term | Meaning |
|---|---|
| **provider** | Plugin that talks to an API. Yours is `bpg/proxmox`. |
| **root module** | A directory you run `terraform apply` in. Has its own state. |
| **state** | Terraform's record of what it created — the map between config and reality. Lose it and Terraform forgets it owns your VMs. |
| **provider alias** | A second configuration of the same provider, one per Proxmox host, so one root can manage all three machines. |
| **`for_each`** | Build N resources from a map instead of copy-pasting N blocks. |
| **`moved` block** | "This resource changed address in config — don't destroy and recreate it." Single-use, and **only works within one state file.** |

### Proxmox

| Term | Meaning |
|---|---|
| **datastore** | Where storage lives. `local` holds files (ISOs, images); `local-lvm` holds block devices (VM disks). Not interchangeable — a common early error. |
| **cloud-init** | First-boot configuration: hostname, IP, SSH keys. How a generic image becomes *your* VM. |
| **resource mapping** | A named alias for a PCI device. Lets an API token use passthrough where a raw PCI ID would not. |

### NixOS

| Term | Meaning |
|---|---|
| **flake** | A directory with `flake.nix` that pins its inputs (the nixpkgs version) in `flake.lock`. Makes builds reproducible. Your repo becomes one. |
| **module** | A `.nix` file contributing configuration. `nix/hosts/dns.nix` is a module. |
| **option** | A setting a module exposes, e.g. `services.forgejo.enable`. Search them at `search.nixos.org/options` — **the tool you will use most.** |
| **derivation** | A build recipe. You will see the word in errors; you rarely write one. |
| **`nixos-rebuild switch`** | Build the config and activate it now. `--target-host` does it over SSH to another machine. |
| **generation** | Every rebuild is a numbered, bootable snapshot of the whole system. |
| **rollback** | Boot the previous generation. This is why NixOS is safe to experiment on. |

### Docker, as NixOS drives it

| Term | Meaning |
|---|---|
| **`virtualisation.docker.enable`** | Installs and runs the Docker daemon on that host. |
| **`virtualisation.oci-containers`** | NixOS's declarative container layer. `backend = "docker"` makes it use Docker; each container becomes a systemd unit. |
| **container as systemd unit** | The practical upshot: `systemctl status docker-pihole`, `journalctl -u docker-pihole`. Containers behave like every other service on the box. |
| **why not compose** | A compose file is a second source of truth that `nixos-rebuild` does not manage — so it drifts, and it is not part of a generation you can roll back. |

---

# Stage 1 — hp16: DNS and Forgejo

One machine. Nothing here touches the Dell or hp32. This stage is where you learn the Terraform +
NixOS loop; the two later stages are the same loop with different services.

### 1.1 — Terraform: one root, built fresh

Create `terraform/infra/` as a **new root with a new, empty state**, declaring the two hp16 VMs
through the existing `terraform/modules/proxmox-vm/` module via `for_each` over a `locals.vms` map.

Every resource is new, so **there is no state migration in this stage** — that cost is deferred to
Stage 2 where the Dell's live VMs are involved.

Define a **provider alias** per Proxmox host now, even though only one is in use. Adding the Dell
in Stage 2 then costs a map entry rather than a restructure.

*Reuse:* `modules/proxmox-vm` needs no changes. Its `ipv4_address` and `user_account` inputs
already do exactly what NixOS cloud-init needs.

*Watch for:* you cannot interpolate a provider alias from a variable. With three hosts you will
likely want one module block per host, each `for_each`-ing a filtered subset of the map. Knowing
this now saves an afternoon.

*Delete afterwards:* `terraform/hosts/hp-sff-16gb/` and the two Talos VMs it manages.

### 1.2 — The NixOS foundation

```
nix/
  flake.nix
  modules/base.nix          # users, SSH key, cloud-init, qemu-guest-agent, timezone, firewall
  modules/docker.nix        # virtualisation.docker + oci-containers backend; imported where needed
  hosts/dns.nix
  hosts/git.nix
```

How a NixOS VM is born and then configured — this mirrors the download-image → cloud-init →
configure flow the repo already uses for Ubuntu, so it adds one new tool, not three:

1. `nixos-generators -f qcow` builds **one** generic base image with your SSH key and
   `services.cloud-init.enable = true` baked in
2. upload it to Proxmox `local` (files go on `local`, never `local-lvm`)
3. Terraform clones it per VM — because the image runs cloud-init, `modules/proxmox-vm` works
   unchanged and sets the static IP and SSH key on first boot
4. `nixos-rebuild switch --target-host root@<ip> --flake .#<host>` applies the real config, and
   every change after

**Step 1's cloud-init is the load-bearing detail.** Without it the VM boots with no address and
you cannot reach it to configure it. This is the fiddliest part of Stage 1 — budget for it, and
solve it before building anything real.

*Done when:* you can `nixos-rebuild switch --target-host` a trivial change **and `--rollback` it.**
Prove rollback works before you depend on it.

### 1.3 — `dns` VM: Pi-hole at `.64`

2 GB. Pi-hole as a Docker container via `virtualisation.oci-containers`, with
`backend = "docker"`. Free port 53 with `services.resolved.enable = false`.

Bind-mount `/etc/pihole` and `/etc/dnsmasq.d` to host paths so the config survives a container
replacement — and so restic can back them up in Stage 3.

Replaces `ansible/playbooks/pihole.yaml` entirely — the `systemd-resolved` masking, the
`setupVars.conf` pre-seed, the unattended installer with its `creates:` guard, and the hand-rolled
string comparison it uses for DNS-record idempotency.

**On the cutover risk:** every guest is configured `dns_servers = [.64, .1]`, so the router is
already the fallback. A failed cutover costs you *filtering and internal `home.arpa` names*, not
external resolution — the lab keeps working, `git.home.arpa` does not. Lower stakes than it looks,
but do it when you have time to finish.

The old Pi-hole LXC holds `.64`, so you cannot build the replacement on that address while it
runs. Either bring the new VM up on a spare address and swap, or destroy the LXC first and accept
a short unfiltered window.

### 1.4 — `git` VM: Forgejo at `.61`

4 GB. This is where the simplification is most visible — the whole service is roughly:

- `services.forgejo` with `settings.server.DOMAIN = "git.home.arpa"` and its `ROOT_URL`
- `services.nginx` with a virtual host for `git.home.arpa` proxying to Forgejo's port
- a firewall rule for 80 and 22

No container, no chart, no manifests, no PVC. Forgejo's data lives at `/var/lib/forgejo` and is
backed up by `services.restic` in Stage 3. SQLite is the right database at this scale; NixOS
defaults to it.

Add the `git.home.arpa → 192.168.0.61` record in Pi-hole.

Delete `ansible/playbooks/deploy-apps.yaml`, `helm-values/forgejo-values.yaml` and `k8s/`.

*Done when:* `git.home.arpa` serves Forgejo, you can push a repo, and the VM survives a reboot with
the repo intact.

---

# Stage 2 — dell: ollama, then TrueNAS, then Jellyfin

### 2.1 — Fold the Dell into `terraform/infra/`

The one genuine state migration in the plan, deferred here because nothing depended on it.
`infra/` has its own state; the Dell's live `ollama` and `truenas` live in a different state file.

**`moved` blocks cannot do this** — they only relocate addresses *within* one state. Crossing state
files needs `terraform state mv -state-out=…`, or `state rm` plus `import`. Back up both state
files before you start.

*Done when:* `terraform plan` in `infra/` reports **"No changes"** against two running machines.

### 2.2 — Fix the TrueNAS trap first

`terraform/hosts/dell/vms.tf` still sets `iso_file_id` and `boot_order = ["ide2", "scsi0"]` on
`module "truenas"`. A plain `apply` re-attaches the install ISO, and because the CD boots first the
VM next boots into the *installer* rather than your system. Remove both lines before any Dell
apply. Full diagnosis: `docs/guide/completed.md` → "Known drift".

While in that file: `modules/proxmox-vm/variables.tf` defaults `dns_servers` router-first, which
silently bypasses Pi-hole. Flip it.

### 2.3 — ollama (first, as you asked)

`services.ollama` with `acceleration = "cuda"` — **native, not containerised.** GPU access from
inside a container additionally needs `hardware.nvidia-container-toolkit`, and there is no reason
to pay for that when the native module works. **open-webui runs as a Docker container**, which is
how upstream ships it; it talks to ollama over HTTP, so splitting them costs nothing.

This replaces `ansible/playbooks/ollama.yaml` — not by removing Docker, but by moving the same
container into `virtualisation.oci-containers`, where it is versioned, rolled back and deployed
with everything else instead of living in a compose file written inline in a playbook. Declare the
model set rather than pulling it imperatively with `docker_container_exec`.

*Note:* the old playbook references `WEBUI_SECRET_KEY` in its compose file and **never defines it
anywhere.** Set it properly via sops-nix (2.6).

GPU passthrough: create an `ollama-gpu` resource mapping and reference it in the VM's `hostpci`
list. `docs/guide/completed.md` lesson 1 explains why a *mapping* works with API-token auth where a
raw PCI ID does not — same procedure as the existing `truenas-it`.

Trim 64 → 48 GB while here: `deepseek-coder:33b` at q4 needs ~20 GB, and the trim makes room for
Jellyfin.

**Expect this to be the slowest task in the whole plan.** GPU passthrough plus NVIDIA drivers on
NixOS is two fiddly things stacked.

### 2.4 — TrueNAS

Unchanged as an appliance. The remaining work is the ZFS pool itself, **blocked on a third drive**
for RAIDZ1, plus the `media`/`downloads` datasets and the NFS export.

### 2.5 — Jellyfin

`services.jellyfin`, greenfield, built as NixOS from the start. The service can go up before 2.4's
pool exists; only the media library depends on it.

### 2.6 — Ansible leaves

`ollama.yaml` was the last playbook. Migrate `ansible/group_vars/all/vault.yml` (it holds
`vault_pihole_webpassword`, and the build guide reserves WireGuard keys for the media stack) to
**sops-nix** first — encrypted in git, works across every NixOS host — then delete `ansible/`
entirely.

---

# Stage 3 — hp32: monitoring and backups

### 3.1 — `backup` VM at `.69`

`services.nfs.server` plus a `restic` repository. Then `services.restic.backups` entries on every
other host — Forgejo's `/var/lib/forgejo` first, since it is the only irreplaceable data in the
lab. Encrypted, deduplicated, with retention, in a few lines per host.

Also the destination for Proxmox `vzdump`. Backups cannot live on the machine they back up, which
is why this is on hp32 and not hp16.

### 3.2 — `monitoring` VM at `.68`

`services.prometheus` with `node_exporter` on every host, and `services.grafana` behind nginx at
`grafana.home.arpa`. Both are native modules; no Helm, no operator, no CRDs.

### 3.3 — Optional

Nextcloud (`services.nextcloud`) if you want file sync and calendar. *But note:*
`docs/hp_sff_32GB.md` says its job is backing up git — and 3.1 already does that far more simply.
If backup is the actual need, skip Nextcloud; it is the heaviest service on the list (PHP,
postgres, redis, nginx).

---

# Later — adding Kubernetes, when you want it

Nothing in the plan above blocks this, and the reserved capacity is deliberate. When you come back:

- **hp32 has 20 GB free and hp16 has 10 GB.** A k3s node fits on either without disturbing what is
  running.
- **`.60`, `.62`, `.63` are reserved** for cluster nodes, and `.70–.79` for a MetalLB pool.
- **The path in:** a single k3s node via `services.k3s` (one NixOS option), then move *one* service
  into it — Forgejo is the natural candidate, since by then you will know exactly what it needs.
  Everything else stays native NixOS until there is a reason to move it.
- **Learn the objects before the tooling.** Namespace → Deployment → Service → Ingress → PVC, by
  hand, on something disposable like nginx. `kubernetes.io/docs/concepts` — the Concepts section,
  not the Tutorials. Helm only after you can read what it generates.
- **Keep DNS out of the cluster, permanently.** A DNS server that needs a working cluster to
  resolve names is a circular dependency that ruins a weekend. This is why `dns` stays its own VM
  regardless of what else changes.

---

## What this replaces

| | Now | After |
|---|---|---|
| Terraform roots / states | 4 | 1 |
| Config languages | Terraform, Ansible, Helm, Talos, kubectl-by-hand | Terraform, Nix |
| Operating systems | Proxmox, Talos, Ubuntu, TrueNAS | Proxmox, NixOS, TrueNAS |
| Containers | Docker, installed by Ansible, compose file inline in a playbook | Docker, declared in NixOS — same rollback and generation history as everything else |
| Hand-typed steps | node labels, namespaces, helm installs, `kubectl apply -f <URL>` | none |

**Deleted — 31 of 53 tracked files:** `ansible/` (7), `terraform/hosts/hp-sff-16gb/` (6),
`terraform/hosts/hp-sff-32gb/` (8), `terraform/hosts/clusters/talos/` (5), `k8s/` (2),
`helm-values/` (1), `.github/workflows/terraform-cd.yaml` (1), and
`docs/guide/kubernetes-the-hard-way.md` — a lab that was never built.

**End state ≈ 33 files:**

| Area | Now | After |
|---|---|---|
| `terraform/` | 30 | **11** (`infra/` 7 + `modules/proxmox-vm/` 4) |
| `nix/` | 0 | 11 |
| `ansible/`, `k8s/`, `helm-values/` | 10 | **0** |
| `docs/` | 8 | 7 |
| `.github/workflows/` | 2 | 1 |
| root + `imgs/` | 3 | 3 |
| **Total** | **53** | **~33** |

**Docs to reconcile:** `README.md` links two files that 404 and still uses the "HP Mini SFF 1/2"
naming that `network-inventory.md` replaced with `dell`/`hp32`/`hp16`. `docs/hp_sff_16GB.md` is
three empty headings and is now the machine you build first. `network-inventory.md` marks live
guests "planned" and needs the new address block. The build guide's Parts 4–12 are obsolete.
`terraform-refactor-plan.md` describes a finished refactor — fold its decision history into
`guide/completed.md`. This plan replaces the untracked `docs/homelab-plan.md` from earlier in this
session.

---

## Verification

Each stage stands alone; stop after any of them and the lab is in a good state.

**Stage 1**
1. `terraform plan` in `infra/` is clean; both VMs answer SSH
2. `nixos-rebuild switch --target-host` applies a change and `--rollback` reverses it
3. `dig git.home.arpa @192.168.0.64` resolves from another machine, and a blocked domain is still
   blocked — verify **before** destroying the old Pi-hole LXC
4. Forgejo serves at `git.home.arpa`, a push succeeds, and the repo survives a VM reboot

**Stage 2**
5. `terraform plan` reports "No changes" after the state move
6. TrueNAS reboots into TrueNAS, not the installer
7. `nvidia-smi` inside the ollama VM sees the RTX 4000; `ollama list` shows the declared models

**Stage 3**
8. Grafana shows `node_exporter` metrics from all hosts
9. **Restore a Forgejo repo from restic onto a scratch VM.** An untested backup is not a backup —
   this is the single most valuable check in the plan.

**Final**, and the one worth aiming at: **rebuild one host from scratch** and confirm the repo
alone is sufficient.

---

## Where to learn each piece

Ordered by when you need it. Given as doc site + section name rather than deep links, because deep
links rot; the exceptions are GitHub repos where the README *is* the documentation.

### The one to bookmark

**`search.nixos.org/options`** — most of your questions in this plan are "what is the option
called", and this answers them in seconds. Search `services.forgejo`, `services.ollama`,
`services.restic`, `virtualisation.oci-containers`.

### Stage 1

| You need to | Read |
|---|---|
| Manage 3 Proxmox hosts from one Terraform root | Terraform docs → *Language → Providers → Configuration*, section "alias: Multiple Provider Configurations". Then *Language → Modules → Providers Within Modules* — how a module **receives** an alias is the part people miss. |
| Build VMs from a map instead of copy-paste | Terraform docs → *Language → Meta-Arguments → for_each* |
| Drive Proxmox from Terraform | `registry.terraform.io/providers/bpg/proxmox/latest/docs` — you want `virtual_environment_vm` and `virtual_environment_download_file` |
| Understand flakes at all | *NixOS & Flakes Book* (`nixos-and-flakes.thiscute.world`) is the best on-ramp — the official docs assume you already know why flakes exist. `nix.dev` is the reference once you do. |
| Structure a multi-host flake | `nixos-and-flakes.thiscute.world` → *Best Practices*, and any of the many public "nix-config" repos on GitHub for shape |
| Build the base VM image | `github.com/nix-community/nixos-generators` README |
| Get cloud-init working in that image | NixOS options search → `services.cloud-init`. **This is the fiddliest step in Stage 1** — solve it on a throwaway VM first |
| Deploy to a remote host | `man nixos-rebuild`, specifically `--target-host` and `--flake` |
| Roll back a bad change | NixOS Manual → *Administration → Rolling Back Configuration Changes* |
| Run containers from NixOS | NixOS options → `virtualisation.oci-containers` (note `backend`) and `virtualisation.docker`. NixOS Wiki → *Docker* |
| Run Pi-hole that way | Pi-hole's own docs → *Docker* for the image, ports, env vars and which paths to persist |
| Run Forgejo natively | NixOS options → `services.forgejo`. Then `forgejo.org/docs` → *Administration → Config Cheat Sheet* for what the `settings` attrset accepts |
| Put nginx in front of it | NixOS options → `services.nginx.virtualHosts`. NixOS Wiki → *Nginx* has working reverse-proxy examples |

### Stage 2

| You need to | Read |
|---|---|
| Move resources between state files | Terraform docs → *CLI → Commands → state mv*, specifically `-state-out`. Back both files up first |
| Pass a GPU into a VM | Proxmox wiki → *PCI(e) Passthrough*. For the token-auth part, `docs/guide/completed.md` lesson 1 in this repo already documents the resource-mapping trick |
| Get NVIDIA working on NixOS | NixOS Wiki → *NVIDIA*, then `hardware.nvidia` in the options search, then `services.ollama.acceleration` |
| Run open-webui in Docker | `docs.openwebui.com` → *Getting Started → Docker*, especially `OLLAMA_BASE_URL` for pointing it at the native ollama |
| Keep secrets in git safely | `github.com/Mic92/sops-nix` README, plus `getsops.io` for age key setup |
| Build the ZFS pool | TrueNAS docs → *Storage → Creating Pools*. RAIDZ1 needs the third drive first |

### Stage 3

| You need to | Read |
|---|---|
| Back up properly | `restic.readthedocs.io` → *Getting Started*, then NixOS options → `services.restic.backups`. **Read the Restore section too** — verification step 9 depends on it |
| Serve NFS | NixOS options → `services.nfs.server.exports` |
| Collect metrics | NixOS options → `services.prometheus` and `services.prometheus.exporters.node`. `prometheus.io/docs` → *Concepts* for what a scrape target and a label actually are |
| Dashboard them | NixOS options → `services.grafana`. Grafana's own *Getting Started* for adding Prometheus as a data source |

### When you come back to Kubernetes

| You need to | Read |
|---|---|
| **Learn the objects** | `kubernetes.io/docs/concepts` — Workloads → Deployments, Services/Networking → Service and Ingress, Storage → Persistent Volumes. **The Concepts section, not the Tutorials.** |
| Run a node | NixOS options → `services.k3s`, plus NixOS Wiki → *K3s* for the inotify and firewall gotchas. `docs.k3s.io` for what it bundles (Traefik, ServiceLB, local-path) |
| A book, if you prefer one | *Kubernetes: Up and Running* (Burns, Beda, Hightower) |

### Reference material already in this repo

- `docs/network-inventory.md` — owns every address; other docs defer to it
- `docs/guide/completed.md` — what already shipped, plus three lessons that superseded the old
  guide. Read its **"Known drift"** section before your first Dell `apply`
