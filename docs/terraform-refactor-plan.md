# Terraform Refactor Plan

Moving the Terraform from per-service root modules to a shared `proxmox-vm` module with one root module per physical machine.

## Why

`terraform/dell/truenas.tf` and `terraform/dell/ollama.tf` are ~85% the same file. Same bios/machine, same efi_disk, same network_device, same ip_config/dns shape. They differ in cores, memory, disk size, vm_id, IP, and two optional blocks (hostpci, cdrom). That is the duplication a module is for.

The second problem is the layout. `terraform/hp-sff/32gb/pihole/` is a root module per service, so every new service on that box needs its own `providers.tf`, `variables.tf`, `terraform init` and its own state file. Forgejo and Nextcloud are both planned for that machine (see `hp_sff_32GB.md`), so that cost is about to be paid three times. The root module should be the machine, not the service.

Pihole stays a plain resource for now. It is an LXC (`_container`, not `_vm`), it is the only one, and there is no duplication to remove yet. Extract a `proxmox-lxc` module when a second container exists — not before.

## Current state of the world

Read from `terraform/dell/terraform.tfstate` (serial 4) before writing this plan:

| Resource | In code | In state | Notes |
|---|---|---|---|
| `proxmox_download_file.ubuntu_cloud_image` | yes | yes | applied |
| `proxmox_virtual_environment_vm.ollama` | yes | yes | applied, running |
| `proxmox_download_file.truenas_iso` | yes | no | never applied |
| `proxmox_virtual_environment_vm.truenas` | yes | no | never applied |
| pihole LXC + template | yes | no state file at all | never applied |

This matters a lot: only ollama is live. Everything else can be rewritten freely with no migration risk. Exactly one `moved` block is needed in the whole refactor.

State is local and gitignored. There is no remote backend.

## Target layout

```
terraform/
  modules/
    proxmox-vm/
      main.tf
      variables.tf
      outputs.tf
  hosts/
    dell/              providers.tf versions.tf variables.tf images.tf vms.tf
    hp-sff-32gb/       providers.tf versions.tf variables.tf pihole.tf
  common.tfvars        gitignored; ssh_public_key and anything shared
```

One state file per machine. Shared inputs come in with `terraform plan -var-file=../../common.tfvars`.

`hp-sff-16gb` gets a root module when there is actually something to put in it.

---

## Phase 0 — Fix what is already broken

None of this is style. Do this phase first and on its own commit.

Note that only the first three are caught by `terraform validate` — they are HCL/reference errors. The three `truenas.tf` disk and boot items below pass `validate` cleanly and only fail at plan/apply time against a real Proxmox, so a green `validate` is not evidence they are fixed.

- [ ] `hp-sff/32gb/pihole/providers.tf:4` — `vat.host_a_api_token` → `var.host_a_api_token`
- [ ] `dell/truenas.tf:35` — references `proxmox_virtual_environment_download_file.truenas_iso` but the resource is declared as `proxmox_download_file`. Both type names are real in `bpg/proxmox` 0.111.1; they just have to match. Use the short `proxmox_download_file` everywhere, because that is what is already in state for `ubuntu_cloud_image` — it avoids a rename.
- [ ] `hp-sff/32gb/pihole/pihole.tf:11` — same mismatch, same fix
- [ ] `dell/truenas.tf:32` — `interface = "sc"` is not a valid interface, needs `scsi0`. The same disk block also has no size.
- [ ] `dell/truenas.tf:39` — `boot_order = ["ide2", "scsi0"]` names ide2, but the cdrom block above it sets no interface. Give the cdrom `interface = "ide2"`.
- [ ] `dell/truenas.tf:43` — `id = "0000:0a:00"` is still the placeholder from the docs. Get the real controller ID off the Dell with `lspci -nn` before applying.

Confirm with `terraform validate` in both directories. Do not proceed until both pass.

---

## Phase 1 — Write the module

Create `terraform/modules/proxmox-vm/`. It wraps `proxmox_virtual_environment_vm` only.

Image downloads stay in the root module, not in `proxmox-vm`. Both Dell VMs pull from local on the same node, and ollama's Ubuntu image will eventually be shared with other VMs. Putting the download inside the module means one download per module call — the same image fetched twice.

**Inputs:**

| Variable | Type | Notes |
|---|---|---|
| `name, vm_id, node_name, datastore` | string / number | required |
| `cores, memory_mb` | number | default 2 / 4096 |
| `disk_size_gb` | number | required |
| `disk_image_id` | string, nullable | cloud image to seed boot disk |
| `iso_file_id` | string, nullable | ISO to attach as cdrom |
| `ipv4_address` | string | CIDR |
| `ipv4_gateway, dns_servers` | string / list | default to 192.168.0.1 and the pihole |
| `hostpci_ids` | list(string) | default [] |
| `user_account` | object, nullable, sensitive | {username, password, keys} |

`cdrom`, `hostpci` and `user_account` are dynamic blocks driven off whether their input is null/empty, so a cloud-image VM and an ISO-install VM both come out of the same module.

**Outputs:** `vm_id`, `name`, `ipv4` (the address with the CIDR suffix stripped — Ansible inventory will want it).

- [ ] `modules/proxmox-vm/{main,variables,outputs}.tf` written
- [ ] `terraform fmt` clean

---

## Phase 2 — Move the Dell root

`git mv terraform/dell terraform/hosts/dell`. Move `terraform.tfstate`, `terraform.tfstate.backup`, `terraform.tfvars` and `.terraform.lock.hcl` with it (the first three are gitignored, so move them by hand). Delete `.terraform/` and re-run `terraform init` — it holds stale entries pointing at a `../modules/proxmox-vm` from an earlier attempt at this that no longer exists.

Then:

- [x] split image downloads into `images.tf`, keeping resource addresses unchanged
- [ ] replace `ollama.tf` + `truenas.tf` with two module blocks in `vms.tf`
- [ ] rename `dell_node_name` → `node_name`, `dell_datastore` → `datastore`, `dell_endpoint` → `endpoint`; the `dell_` prefix is redundant once the root is the machine. Update `terraform.tfvars` to match.
- [ ] add the one moved block:

```hcl
moved {
  from = proxmox_virtual_environment_vm.ollama
  to   = module.ollama.proxmox_virtual_environment_vm.this
}
```

truenas needs no moved block — it is not in state.

- [ ] `terraform plan` and read it carefully. It must report 1 move, 0 destroy, plus creates for the truenas VM and its ISO. If it wants to destroy ollama, stop; the address in the moved block is wrong.
- [ ] apply
- [ ] delete the moved block in a follow-up commit once applied

---

## Phase 3 — Move the HP SFF root

`git mv terraform/hp-sff/32gb/pihole terraform/hosts/hp-sff-32gb`. No state exists, so nothing to migrate — but `vault.yaml` is tracked in git and must come along.

- [ ] rename `host_a_*` variables to match the Dell naming (`endpoint`, `node_name`, `datastore`, `api_token`)
- [ ] `terraform validate` passes

---

## Phase 4 — Auth consistency

Dell authenticates as `root@pam` with a password; HP SFF uses an API token. Standardise on the token — it can be scoped, and it does not put the root password in a tfvars file.

- [ ] create a Terraform API token on the Dell in the Proxmox UI
- [ ] `dell/providers.tf` → `api_token`, drop password
- [ ] drop the `dell_root_password` variable
- [ ] both providers get the same `ssh { agent = true }` block the HP SFF one already has

---

## Phase 5 — CI

The workflow now runs on `pull_request`. Two things are wrong with it independently of this refactor:

- [ ] the matrix lists `terraform/hp-sff/16gb`, which does not exist — that job fails at checkout. Remove it until the machine has a root module.
- [ ] `terraform plan` runs with no tfvars and no Proxmox credentials, so it can only ever fail. Either stop the pipeline at validate, or put the endpoint and API token in GitHub secrets and pass them as `TF_VAR_*`. Stopping at validate is the right call for now — a homelab Proxmox on 192.168.0.x is not reachable from a GitHub runner anyway.

Then update for the new layout:

- [ ] matrix becomes `terraform/hosts/dell` and `terraform/hosts/hp-sff-32gb`
- [ ] checkov `directory:` → `terraform/` so it covers the modules too
- [ ] bump `actions/checkout@v3` → `v4` in the terraform job (the checkov job is already v4)
- [ ] add a `terraform fmt -check -recursive` run at the repo root so `modules/` is covered — the per-directory `fmt -check` will not see it

---

## Not in scope

- **Remote state.** Local state is fine while this is one operator on one laptop. Revisit if a second machine ever runs apply.
- **A `proxmox-lxc` module.** Wait for the second container (Forgejo or Nextcloud).
- **Ansible.** The inventory hardcodes IPs that the module now outputs, so wiring `terraform output` into `ansible/inventory.yml` is worth doing — but as its own piece of work, after this lands.

---

## Order of commits

1. Phase 0 fixes, alone, so the "make it valid" diff is readable
2. Phase 1 module, unused by anything
3. Phase 2 Dell move + moved block + apply
4. Phase 2 cleanup: remove moved block
5. Phase 3 HP SFF move
6. Phase 4 auth
7. Phase 5 CI