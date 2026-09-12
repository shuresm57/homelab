# Completed — what's already built

Lifted out of the old Talos build guide, which has since been deleted along with the cluster it
described. This is a record, not instructions: don't re-run any of it. Addresses
and names live in [network-inventory.md](../network-inventory.md).

Verified against Terraform state serial 22 (`terraform/hosts/dell/terraform.tfstate`), not from
memory.

---

## Dell host prep

- Renamed to node `dell`.
- VT-d enabled in BIOS; `intel_iommu=on iommu=pt` in `GRUB_CMDLINE_LINUX_DEFAULT`.

Both are proven rather than assumed: the TrueNAS VM below passes an HBA through with
`hostpci0 { mapping = "truenas-it", pcie = true }`, live in state. That cannot work without IOMMU.

---

## The `proxmox-vm` module

The single biggest change from the original guide, which taught duplicated
`proxmox_virtual_environment_vm` blocks per VM. Everything now goes through
`terraform/modules/proxmox-vm/`.

**What it hardcodes** (so you don't repeat it, and so a change lands everywhere at once):
`bios = "ovmf"`, `machine = "q35"`, `cpu.type = "host"`, `efi_disk` raw/`4m`,
`network_device.bridge = "vmbr0"`, boot disk on `scsi0`, `agent { enabled = false }`.

**Inputs:** `name`, `vm_id`, `node_name`, `datastore`, `disk_size_gb`, `ipv4_address` are required
(with validation — `ipv4_address` is regex-checked as CIDR). `cores` defaults 2, `memory_mb` 4096,
`ipv4_gateway` `192.168.0.1`, `dns_servers`, `boot_order`, `disk_image_id`, `iso_file_id`,
`user_account`, `hostpci_mappings`.

**Two dynamic blocks carry the interesting logic:**

```hcl
dynamic "cdrom" {                                    # only when installing from an ISO
  for_each = var.iso_file_id == null ? [] : [var.iso_file_id]
  content { file_id = cdrom.value, interface = "ide2" }
}

dynamic "hostpci" {                                  # device index comes from list position
  for_each = var.hostpci_mappings
  content { device = "hostpci${hostpci.key}", mapping = hostpci.value, pcie = true }
}
```

`user_account` is a third, emitted only when non-null — which is why TrueNAS gets a cloud-init
drive but no user account (it's installed from ISO, cloud-init would be meaningless).

**Outputs:** `vm_id`, `name`, and `ipv4` (which strips the `/24` off `ipv4_address`, so consumers
get a bare address).

---

## Dell root module — `terraform/hosts/dell/`

Applied and live. Four resources in state:

```
proxmox_download_file.ubuntu_cloud_image
proxmox_download_file.truenas_iso
module.ollama.proxmox_virtual_environment_vm.this
module.truenas.proxmox_virtual_environment_vm.this
```

| | ollama | truenas |
|---|---|---|
| vm_id | 702 | 700 |
| CPU / RAM | 6 cores / 64GB | 4 cores / 16GB |
| Disk | 80GB from Ubuntu 24.04 cloud image | 32GB boot, installed from ISO |
| IP | `192.168.0.67/24` | `192.168.0.65/24` |
| Extras | cloud-init user `ubuntu` + SSH key + console password | `hostpci_mappings = ["truenas-it"]`, `boot_order = ["ide2","scsi0"]` |

`images.tf` holds both downloads separately from the VMs, so re-applying a VM never re-downloads a
multi-GB image.

---

## TrueNAS — built, then retired

TrueNAS SCALE **25.10.5** (Goldeye) installed onto the 32GB boot disk; web UI reachable at
`192.168.0.65`.

**This guest is being deleted.** The pool never got built — it was blocked on a third drive, and
by the time the fourth arrived the design had changed: the ZFS pool now lives directly on the
`media` VM, which takes over the HBA passthrough, and nothing serves NFS any more. See
[homelab-plan.md](../homelab-plan.md) §2.1 for the retirement and §2.4 for what replaced it.
The section below still matters, because you have to get past it to delete the VM safely.

### ⚠️ Known drift — do not `apply` the Dell without reading this

`terraform plan` in `terraform/hosts/dell/` currently reports one in-place change:

```
~ cdrom {
    ~ file_id = "none" -> "local:iso/TrueNAS-SCALE-25.10.5.iso"
  }
```

The install ISO was ejected on the host after TrueNAS was installed; the config still asks for it.
Applying would **re-attach the installer** — and because `module.truenas` still sets
`boot_order = ["ide2", "scsi0"]` with the CD first, the next boot of that VM would land in the
TrueNAS installer instead of your installed system.

The install is finished, so the config should stop describing an install. In
`terraform/hosts/dell/vms.tf`, drop both lines from `module "truenas"`:

```hcl
  iso_file_id      = proxmox_download_file.truenas_iso.id     # remove
  boot_order       = ["ide2", "scsi0"]                        # remove
```

With `iso_file_id` null the module's `dynamic "cdrom"` block emits nothing, and with `boot_order`
null the VM boots `scsi0`. Keep the `proxmox_download_file.truenas_iso` resource in `images.tf` —
it costs nothing and you'll want it if you ever rebuild.

(The plan also wants to add `initialization.datastore_id = "local-lvm"`, which is harmless — that
attribute simply wasn't recorded in state when the VM was created.)

---

## hp16 — dns and git

Both VMs are running. `dns` (`.64`) serves Pi-hole natively; `git` (`.61`) serves Forgejo behind
nginx. The configuration **is** the documentation now — read the files rather than a guide that
can drift from them:

```
terraform/infra/          providers.tf  variables.tf  main.tf  terraform.tfvars (gitignored)
terraform/modules/proxmox-vm/
nix/flake.nix             nixpkgs pinned to nixos-26.05
nix/data/network.nix      host -> IP inventory
nix/modules/base.nix      cloud-init, ssh, disk layout, bootloader
nix/modules/forgejo.nix   homelab.services.forgejo
nix/modules/pihole.nix    homelab.services.pihole
nix/hosts/dns.nix         turns Pi-hole on
nix/hosts/git.nix         turns Forgejo on, declares the two backup sticks
```

Operational commands live in `docs/commands.md` (gitignored, local only).

---

## The Nix module layer

`nix/` started as two flat host files. It is now a small module system, and the shape is worth
knowing before you add a fourth host.

**Every host imports every module.** `nix/modules/default.nix` is a bare `imports` list pulled in
by `mkHost`, and each module declares its own `homelab.*` options with `mkEnableOption` and wraps
its body in `config = lib.mkIf cfg.enable`. A host file is then hostname, hardware, and a few
option values — `nix/hosts/git.nix` went from 69 lines to 36 this way. The one rule this imposes:
a module that is imported everywhere **must** be gated, which is why `docker.nix` grew a
`homelab.docker.enable` flag it did not have when nothing imported it.

**`nix/data/network.nix` is the host→IP table.** `homelab.services.pihole.records` defaults to
it, so Pi-hole's local DNS is generated from the same file a future host would read.

**The Forgejo backup is upstream's now.** It used to be a hand-written
`systemd.services.forgejo-backup` shelling out to `forgejo dump`. It is `services.forgejo.dump`,
which brought two things the hand-rolled version never had:

- **Retention.** The module emits `d '<backupDir>' 0750 forgejo forgejo <age> -`, so
  systemd-tmpfiles prunes old archives. The old script kept every zip forever, on both sticks.
- **A name that does not collide.** The old script evaluated `$(date +%F)` twice — once for the
  dump and once for the copy — so a run crossing midnight copied a file that did not exist.
  Leaving `dump.file` null lets Forgejo timestamp each archive itself.

Two things upstream does *not* give you, added on top:

- **`RequiresMountsFor`** on `forgejo-dump.service`. The sticks are mounted `nofail`, so without
  it a dump with a disk absent writes into the bare mountpoint on the root filesystem and exits
  0. It looks like a successful backup and is not one.
- **`Persistent = true`** on the timer, so a dump missed while the VM was off is caught up.

The `cp` to the second stick became `forgejo-dump-mirror.service`, `wantedBy` the dump unit, and
runs `rsync -rt --delete --no-perms --no-owner --no-group`. No `-a`: the sticks are exfat and
vfat and cannot store unix ownership. `--delete` makes the mirror inherit the pruning for free.

**How to prove a refactor changed nothing.** Evaluation is platform-independent, so from the Mac:

```bash
nix eval --raw '.#nixosConfigurations.dns.config.system.build.toplevel.drvPath'
nix eval --raw 'git+file:///path/to/homelab?dir=nix&ref=refs/heads/main#nixosConfigurations.dns.config.system.build.toplevel.drvPath'
```

Identical hashes mean the two configurations are the same derivation — nothing was built to find
out. The Pi-hole move into a module came out bit-identical this way; the Forgejo one differed in
exactly the three expected systemd units. Note the `ref=` — without it the flake URL reads your
dirty working tree and you compare a tree against itself.

**Flakes only see tracked files.** A new `.nix` file that has not been `git add`ed does not exist
as far as `nix eval` is concerned, and the error names a missing path rather than an untracked
one.

---

## Lessons that superseded the original guide

Recording these because the old guide asserted the opposite, confidently, and the working config
proves it wrong. If you ever find yourself reading old notes, trust this section.

### 1. API token auth works fine with PCI passthrough

The original guide claimed:

> *"Root user/password, not an API token — `hostpci` passthrough isn't compatible with token auth."*

That's wrong. `terraform/hosts/dell/providers.tf` uses `api_token` plus an `ssh { agent = true }`
block, and passes an HBA through successfully. The thing that makes it work is using a **resource
mapping** instead of a raw PCI ID:

- Proxmox UI → **Datacenter → Resource Mappings → PCI Devices** → create a mapping named
  `truenas-it` bound to the HBA.
- Terraform refers to it by name: `hostpci_mappings = ["truenas-it"]` → `mapping = "truenas-it"`.

Better than the old `id = "0000:0a:00"` approach for three reasons: the ID survives a PCI
renumbering after a hardware change, the mapping is what the API permits a token to use, and the
name says what the device *is*.

The `ssh` block is still required — the provider uploads images over SCP, not through the API — so
the SSH key for `proxmox_ssh_user` must be in a loaded ssh-agent when you run Terraform.

### 2. ISOs and templates go on `local`; disks go on `local-lvm`

`local-lvm` is an LVM-thin pool. It stores block devices, and *cannot* store files — so ISOs,
container templates, and cloud images will not go there. This is why `images.tf` hardcodes
`datastore_id = "local"` while the module gets `local-lvm` for `efi_disk`, `disk` and
`initialization`.

The symptom when you get it wrong is an unhelpful storage-type error at apply time, not at plan
time.

### 3. `moved` blocks are single-use

Refactoring the Dell VMs into the module needed:

```hcl
moved {
  from = proxmox_virtual_environment_vm.ollama
  to   = module.ollama.proxmox_virtual_environment_vm.this
}
```

Once applied, state holds the new address and the block does nothing forever. It has been removed.
Keep such a block only until every state that could contain the old address has been migrated —
here that's one local, gitignored state file, so one apply was enough.

### 4. Pi-hole does not need Docker

The build guide ran it as a container because `services.pihole` does not exist in nixpkgs
**25.05**. It does exist in **25.11+** as `services.pihole-ftl` + `services.pihole-web`. The
container version caused four separate failures — port 53 contention, an image that could not be
pulled without DNS, queries silently dropped by dnsmasq's `LOCAL` mode behind Docker's bridge
NAT, and no declarative password. Bumping the flake to `nixos-26.05` and using the native module
removed all four. **When something has no NixOS module, check whether your pin is simply old
before reaching for a container.**

### 5. Never disable `systemd-resolved` to free port 53

Use:

```nix
services.resolved.settings.Resolve.DNSStubListener = false;
```

`services.resolved.enable = false` leaves the machine with *no resolver at all*, which means it
cannot fetch the closure that would fix it. That is an unrecoverable deadlock without an
out-of-band edit to `/etc/resolv.conf`. Also set `networking.nameservers` to the router: a DNS
server that resolves through itself cannot bootstrap.

### 6. The Terraform provider needs an SSH username

Token auth carries no SSH identity, so `ssh { agent = true; }` alone connects as `""` and fails
at disk creation:

```hcl
ssh { agent = true; username = "root"; }
```

### 7. A qcow2 goes in the `import` datastore, not `iso`

PVE's `$ISO_EXT_RE` accepts only `.iso` and `.img`; a `.qcow2` under `local:iso/` fails with
*"unable to parse directory volume name"* and is invisible to `pvesm list`. Use
`local:import/nixos-base.qcow2`.

### 8. `nixos-rebuild` from macOS needs `--no-reexec` and `--build-host`

Without `--no-reexec` it tries to build an `x86_64-linux` copy of itself locally and dies on
platform mismatch. It also needs `--build-host`, since macOS cannot build Linux derivations.
Evaluation is platform-independent and works fine locally — which is what makes the `drvPath`
comparison above usable from a laptop.

### 9. `nixos-generate -c` needs an explicit nixpkgs pin

It resolves `<nixpkgs>` through `NIX_PATH`, the pre-flakes mechanism. On a flakes-only install
that is empty. Pin it to the rev from `flake.lock` so the image matches the flake.

### 10. Provider aliases cannot be dynamic

Terraform resolves providers before evaluating `for_each`, so
`provider = proxmox[each.value.host]` is impossible. That single constraint is why `main.tf` has
one `module` block per host, and why the VM map is nested by host rather than flat and filtered —
the nesting mirrors a limitation you cannot design around.

### 11. `for_each` over a map, never `count`

With `count`, resources are addressed by index, so deleting one VM renumbers the rest and
destroys machines you did not touch. `for_each` gives you `module.hp16["dns"]`, stable forever.

### 12. The image and the flake are two separate evaluations

`nixos-generators` supplies `fileSystems` and a bootloader while building the image; your flake
does not import that module, so `base.nix` must declare them itself or `nixos-rebuild` fails with
*"The `fileSystems` option does not specify your root file system."* Match the bootloader to the
firmware — the Terraform module sets `bios = "ovmf"`, so it is systemd-boot and an ESP at
`/boot`, not BIOS GRUB.

### 13. `system.stateVersion` is not a version to bump

It records which release's *stateful* defaults this machine expects, so upgrading nixpkgs cannot
silently migrate data underneath you. It stayed `"25.05"` through the jump to 26.05, correctly.

### 14. Generated config beats copied config

`nix/data/network.nix` holds one attrset of host→IP records, and Pi-hole's host list is derived
from it:

```nix
hosts = lib.mapAttrsToList (name: ip: "${ip} ${name}") cfg.records;
```

Addresses stop being a hand-copied list that drifts from `network-inventory.md`. The table
started life inline in `dns.nix`; moving it to `data/` is what made it usable by anything other
than Pi-hole.

### 15. Secrets have a declarative path, usually

The Pi-hole admin password is a BALLOON-SHA256 hash in
`homelab.services.pihole.web.passwordHash`, generated without ever writing to disk:

```bash
FTLCONF_webserver_api_password="$PW" pihole-FTL --config webserver.api.pwhash
```

The module sets `misc.readOnly = true` so runtime changes cannot silently diverge from config —
which is why the password could not be set with `pihole setpassword`.
