# Completed — what's already built

Lifted out of [the build guide](proxmox-talos-k8s-build-guide.md) so that guide only contains work
that's still ahead of you. This is a record, not instructions: don't re-run any of it. Addresses
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

## TrueNAS

TrueNAS SCALE **25.10.5** (Goldeye) installed onto the 32GB boot disk; web UI reachable at
`192.168.0.65`.

Not done, and tracked in the main guide: the ZFS pool itself, which is **blocked on the third
drive** for a 3-disk RAIDZ1, plus the `media`/`downloads` datasets and the NFS export.

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
