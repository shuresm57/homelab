# Proxmox + Talos Kubernetes — build guide

**What's left to do.** Work already finished has moved to
[completed.md](completed.md) — the Dell host prep, the `proxmox-vm` Terraform module, the Ollama
and TrueNAS VMs, and the auth/storage lessons that came out of building them.

All addresses and names come from [network-inventory.md](../network-inventory.md). This guide
refers to names; that file owns the numbers. If they ever disagree, the inventory wins.

Markers used throughout:

- 📄 **File** — content to save at that path. Create it, don't run it.
- ▶️ **Run** — a command to type, not something to save.
- ✅ **Checkpoint** — don't move on until it passes.
- 🚧 **Blocked** — waiting on hardware; skip until it arrives.

## Where you are right now

| | |
|---|---|
| **Dell** (`dell.home.arpa`, `.254`) | Ollama VM and TrueNAS VM both live. TrueNAS installed, UI up. Ollama running — API on `:11434`, open-webui on `:3000`. |
| **hp32** (`.129`) | Proxmox up, node named `hp32`. Pi-hole LXC applied and **Pi-hole v6 running** on `.64`, blocking active, `home.arpa` records published. |
| **hp16** (`.125`) | Proxmox up. No Terraform at all yet. |
| **Next** | **Part 4** — Talos VMs. Parts 1–3 are done. |
| **Outstanding from Part 3** | The router's DHCP still hands out its own DNS. Point it at `.64` when you're ready to commit the whole house to Pi-hole. |
| **Blocked on hardware** | Third drive for the RAIDZ1 pool → TrueNAS pool, then Jellyfin. |

Order of play: ~~unblock Ansible~~ → ~~Ollama~~ → ~~Pi-hole~~ → Talos cluster → Forgejo →
Nextcloud → Grafana/Prometheus. TrueNAS pool and Jellyfin come in whenever the drive shows up.

Everything except Pi-hole runs **inside the Talos cluster**. Pi-hole stays a plain LXC on purpose:
it's the DNS the cluster itself depends on, and a DNS server that needs a working cluster to
resolve names is a circular dependency waiting to ruin a weekend.

## Repo layout

```
homelab/
├── ansible/
│   ├── inventory.yml
│   ├── vault.yaml
│   └── playbooks/{ollama.yml, pihole.yaml}
├── docs/
│   ├── network-inventory.md          # addresses and names — the source of truth
│   └── guide/{proxmox-talos-k8s-build-guide.md, completed.md, kubernetes-the-hard-way.md}
├── helm-values/                      # empty; filled in Parts 7–9
└── terraform/
    ├── modules/proxmox-vm/           # every VM goes through this
    ├── hosts/                        # one root module per physical machine
    │   ├── dell/                     # ollama, truenas  (applied)
    │   ├── hp-sff-32gb/              # pihole, cp-1, worker-1
    │   └── hp-sff-16gb/              # worker-2, worker-3   (to be created, Part 4)
    ├── clusters/talos/               # Talos bootstrap, spans both HP hosts  (Part 5)
    └── labs/kthw/                    # throwaway hard-way lab  (separate doc)
```

Each directory under `hosts/`, `clusters/` and `labs/` is **its own Terraform state**. You `init`
and `apply` inside each one separately; they never touch each other. That's deliberate — it means
destroying the KTHW lab can't take Pi-hole with it, and rebuilding the cluster can't touch the Dell.

Versions in play: Terraform 1.14.9, `bpg/proxmox` locked at 0.111.1 (constraint `~> 0.111`).

### Calling the module

Every VM from here on looks like this. Only the arguments change:

```hcl
module "worker_1" {
  source = "../../modules/proxmox-vm"

  name         = "worker-1"
  vm_id        = 611
  node_name    = var.node_name
  datastore    = var.datastore
  cores        = 4
  memory_mb    = 10240
  disk_size_gb = 80
  ipv4_address = "192.168.0.61/24"
  dns_servers  = ["192.168.0.64", "192.168.0.1"]
}
```

Pass `disk_image_id` to boot from a cloud image, or `iso_file_id` + `boot_order` to install from an
ISO. Full input list is in [completed.md](completed.md#the-proxmox-vm-module).

---

## Part 1 — Unblock Ansible · ~30–45 min

**This is the next thing you do.** Nothing else in this guide works until `ansible -m ping` returns
`pong`.

### 1.1 The actual problem: it's the username, not the key

Your SSH key is fine. `ansible/inventory.yml` is connecting as users that don't exist:

| Inventory says | Reality |
|---|---|
| `ansible_user: ollama` (line 10) | Cloud-init created **`ubuntu`** — `terraform/hosts/dell/vms.tf:16`, confirmed in live state. There is no `ollama` account on that box. |
| `ansible_user: pihole` (line 15) | The Pi-hole LXC's `user_account` block sets `keys` only with no `username`, so **`root`** is the only account. (That container also doesn't exist yet — Part 3.) |

📄 **`ansible/inventory.yml`**
```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
  children:
    ollama:
      hosts:
        ollama:
          ansible_host: 192.168.0.67
          ansible_user: ubuntu
    pihole:
      hosts:
        pihole:
          ansible_host: 192.168.0.64
          ansible_user: root
```

### 1.2 If the key still doesn't work after that

Cloud-init writes `authorized_keys` **once, on first boot**. If the key in `terraform.tfvars`
changed after the VM was created, Terraform will happily update the cloud-init drive and nothing
will happen inside the guest.

Fix it by hand — you already have the credentials for this. In the Proxmox UI, open the `ollama`
VM's **Console**, log in as `ubuntu` with the `ollama_console_password` from
`terraform/hosts/dell/terraform.tfvars`, then:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAA...your-key' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Then work up the ladder — never debug Ansible before raw SSH works:

▶️ **Run:**
```bash
ssh-add -l                              # is the key even loaded?
ssh -v ubuntu@192.168.0.67 hostname     # raw SSH, verbose
```

### 1.3 Give Ansible a config file

There isn't one, which is why the private key, inventory path and vault password all have to be
remembered on every invocation.

📄 **`ansible/ansible.cfg`**
```ini
[defaults]
inventory            = inventory.yml
host_key_checking    = False
private_key_file     = ~/.ssh/id_ed25519
vault_password_file  = ~/.ansible-vault-pass
interpreter_python   = auto_silent
stdout_callback      = default
result_format        = yaml

[ssh_connection]
pipelining = True
```

`host_key_checking = False` is acceptable on a LAN where VMs get rebuilt constantly and would
otherwise trip host-key mismatches every time. Put your vault password in
`~/.ansible-vault-pass` (mode `600`, outside the repo).

Run playbooks **from inside `ansible/`** so this file is picked up — Ansible only reads
`ansible.cfg` from the current directory, not from a parent.

### 1.4 Declare the collections

The playbooks use `community.docker` and later `kubernetes.core`, but nothing declares them.

📄 **`ansible/requirements.yml`**
```yaml
collections:
  - name: community.docker
  - name: kubernetes.core
  - name: ansible.posix
```

▶️ **Run:**
```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

### 1.5 Fix the vault so it actually loads

`ansible/vault.yaml` sits at a path no playbook reads, and `pihole.yaml` has no `vars_files` — so
`vault_pihole_webpassword` is undefined at runtime. It needs to move where Ansible auto-loads it
for every host. **Moving it alone is not enough**, and the failure is misleading.

The original file encrypts a *bare password string* — one line, no `key: value`. Harmless while
nothing loads it; fatal in `group_vars/`, which must decrypt to a dict of variables. Move it as-is
and every command dies with:

```
[ERROR]: Could not process '.../group_vars/all/vault.yml': failed to combine variables,
expected dicts but got a 'dict' and a '_AnsibleTaggedStr'
```

That names no variable and points at no line, so it reads like a corrupt vault. It isn't —
`_AnsibleTaggedStr` is Ansible saying *"this decrypted to a string where I needed a mapping."*
You can't diagnose it with `grep` either: the file is ciphertext, so there are no plaintext `key:`
lines to match. Use `ansible-vault view`.

▶️ **Run:**
```bash
mkdir -p ansible/group_vars/all
git mv ansible/vault.yaml ansible/group_vars/all/vault.yml
ansible-vault view ansible/group_vars/all/vault.yml     # bare string, or already key: value?
```

If it's a bare string, rewrap it — `ansible-vault edit` opens the plaintext in `$EDITOR`; turn the
lone line into a mapping, keeping the existing value:

```yaml
vault_pihole_webpassword: "the-string-that-was-already-there"
```

Add `vault_webui_secret_key` while you're in there — Part 2 needs it.

> **Don't pass `--vault-password-file` when `ansible.cfg` already sets `vault_password_file`.**
> Two sources both named `default` gives you `ERROR: The vault-ids default,default are available
> to encrypt. Specify the vault-id to encrypt with --encrypt-vault-id`. Drop the flag; let the
> config supply it.

✅ **Verify it loads** — prints the length, never the secret:
```bash
cd ansible
ansible localhost -m debug -a msg="length={{ vault_pihole_webpassword | length }}"
```

### 1.5b Stop the group/host name collision

Two warnings on every command:

```
[WARNING]: Found both group and host with same name: ollama
[WARNING]: Found both group and host with same name: pihole
```

The inventory has a group `ollama` whose only host is also `ollama`. Harmless in itself, but it
trains you to skim past warnings — a bad habit for the day a real one appears. Rename the
**hosts**; playbooks target the groups (`- hosts: ollama`), so nothing else changes:

```yaml
    ollama:
      hosts:
        ollama-vm:            # was: ollama
          ansible_host: 192.168.0.67
          ansible_user: ubuntu
    pihole:
      hosts:
        pihole-lxc:           # was: pihole
          ansible_host: 192.168.0.64
          ansible_user: root
```

### 1.6 Fix the syntax error in the Pi-hole playbook

`ansible/playbooks/pihole.yaml:4` uses `=` instead of `:` inside a `vars:` mapping. **The file does
not parse at all** in its current state:

```yaml
  vars:
    pihole_webpassword = "{{ vault_pihole_webpassword }}"    # ← broken
```

Change it to `pihole_webpassword: "{{ vault_pihole_webpassword }}"`.

✅ **Checkpoint:**
```bash
cd ansible
ansible ollama -m ping                                  # → pong
ansible-playbook --syntax-check playbooks/pihole.yaml   # → no errors
```

---

## Part 2 — Ollama · ~20–40 min

The VM is already running. This just installs the software.

### 2.1 What the playbook actually does

`ansible/playbooks/ollama.yml` (already written) installs **Docker CE** from Docker's own apt repo
— not `docker.io` from Ubuntu — then brings up two containers:

| Container | Port | Notes |
|---|---|---|
| `ollama` | `11434` | The API. Model data in the `ollama-data` volume. |
| `open-webui` | `3000` → 8080 | Chat UI, talks to `http://ollama:11434` over the compose network |

Then it pulls **`deepseek-coder:33b`** (~19GB at Q4 — the VM has 64GB, so there's room for a 70B
later if you want one).

### 2.2 One thing to fix before running it

The compose file references `${WEBUI_SECRET_KEY}` but nothing ever sets it, so it expands to empty
and open-webui generates a fresh signing key on every restart — logging everyone out. Add it to
the vault and write it as an env file:

▶️ **Run:**
```bash
cd ansible
ansible-vault edit group_vars/all/vault.yml     # add: vault_webui_secret_key: "<random string>"
```

Then in `playbooks/ollama.yml`, before the `Compose up` task:

```yaml
    - name: Write compose env file
      copy:
        dest: /opt/ollama/.env
        content: "WEBUI_SECRET_KEY={{ vault_webui_secret_key }}\n"
        mode: "0600"
```

### 2.3 Run it

▶️ **Run:**
```bash
cd ansible
ansible-playbook playbooks/ollama.yml
```

The model pull is slow and silent. `docker logs -f ollama` on the box if you want to watch.

✅ **Checkpoint:** `curl http://192.168.0.67:11434` returns `Ollama is running`, the UI loads at
`http://192.168.0.67:3000`, and `curl http://192.168.0.67:11434/api/tags` lists
`deepseek-coder:33b`.

---

## Part 3 — Pi-hole on hp32 · ~1 hr

DNS first, before the cluster — every Talos VM points at `.64` from first boot. Until this exists
they fall through to the router, which works but means none of the `home.arpa` names resolve.

### 3.1 Proxmox prep on hp32

- [ ] Rename the node to `hp32` (it's empty, so now is the moment — see
      [network-inventory.md](../network-inventory.md#naming)).
- [ ] **Datacenter → Permissions → API Tokens** — create `terraform@pve`, uncheck *Privilege
      Separation* or grant a role with `VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`,
      `Datastore.AllocateSpace`, `Datastore.Audit`, `Sys.Modify` on `/`.
- [ ] Add your SSH public key to `root@hp32` — the provider uploads templates over SCP, not
      through the API, so token auth alone isn't enough.
- [ ] Confirm the storage names: `local` for templates, `local-lvm` for disks.

### 3.2 Fix the template datastore

`terraform/hosts/hp-sff-32gb/pihole.tf:3` downloads the LXC template to `var.datastore`, which is
`local-lvm`. That will fail at apply — `local-lvm` is an LVM-thin pool and can't hold files. Same
bug that was already fixed on the Dell.

```hcl
resource "proxmox_download_file" "ubuntu_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "local"        # was var.datastore
  node_name    = var.node_name
  url          = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}
```

Verify the exact template filename first — the version drifts, and a stale URL 404s:

▶️ **Run, on hp32:** `pveam update && pveam available | grep ubuntu-24`

### 3.3 Real values

📄 **`terraform/hosts/hp-sff-32gb/terraform.tfvars`** — replacing the placeholders
```hcl
endpoint       = "https://192.168.0.129:8006"
api_token      = "terraform@pve!terraform=<the-uuid-from-3.1>"
node_name      = "hp32"
datastore      = "local-lvm"
ssh_public_key = "ssh-ed25519 AAAA...your-actual-key"
```

▶️ **Run, inside `terraform/hosts/hp-sff-32gb/`:**
```bash
terraform init
terraform plan
terraform apply
```

### 3.4 Install Pi-hole ✅ done

▶️ **Run:**
```bash
cd ansible
ansible-playbook playbooks/pihole.yaml
```

Installs **Pi-hole v6** (Core v6.4.3 / Web v6.6 / FTL v6.7) and publishes the local DNS records in
one pass. Re-running reports `changed=0`.

The playbook was rewritten for v6 during this step; four things about v6 are worth knowing, because
every v5-era guide on the internet gets them wrong:

| | |
|---|---|
| **`WEBPASSWORD` env var is ignored** | v6 only accepts `pihole setpassword <pw>`. |
| **`setupVars.conf` is consumed, not kept** | The installer migrates it into `/etc/pihole/pihole.toml` and deletes it — so guard the pre-seed on `pihole.toml`, never on `setupVars.conf`, or the task re-fires forever. |
| **`/etc/pihole/custom.list` no longer exists** | Local records live in `pihole.toml` under `dns.hosts`, written with `pihole-FTL --config dns.hosts '[...]'`. |
| **No lighttpd** | FTL serves the admin UI itself, on port 80. |

The container is a bare Ubuntu 24.04 image, so two things have to happen before the installer runs:

- **`curl` isn't installed.** The install task is `curl -sSL … | bash` and dies instantly without it.
- **`systemd-resolved` holds `127.0.0.53:53` and `127.0.0.54:53`.** FTL binds `0.0.0.0:53` and
  collides. The playbook stops, disables and masks it. Safe here because Proxmox writes
  `/etc/resolv.conf` pointing at the router, not at the resolved stub.

### 3.5 Local DNS records ✅ done

The playbook now writes these from its own `pihole_dns_records` list, mirroring
[network-inventory.md](../network-inventory.md#pi-hole-local-dns-records). Edit them there and
re-run — don't click them into the UI, or the next run will silently revert your changes.

> **If blocking looks broken, restart FTL — don't `pihole restartdns`.**
> Rebuilding gravity replaces `gravity.db` by rename. A running FTL keeps the old inode and logs
> `ERROR: SQLite3: no such table: main.gravity` on *every* lookup, answering with the real upstream
> IP. Blocking is silently off while `pihole status` still says it's on and `dns.blocking.active`
> still reports `true`. `systemctl restart pihole-FTL` is the fix, and the playbook's handler does
> exactly that.
>
> `tail /var/log/pihole/FTL.log` is where this shows up. Nothing else surfaces it.

Then point the LAN at it: router → DHCP → DNS server → `192.168.0.64`. Do this only after the
checkpoint below passes, or you'll take the whole house's DNS down with it. **Still outstanding.**

✅ **Checkpoint:**
```bash
dig +short @192.168.0.64 google.com                # upstream → real IPs
dig +short @192.168.0.64 truenas.home.arpa         # → 192.168.0.65, local records work
dig +short @192.168.0.64 ad-assets.futurecdn.net   # → 0.0.0.0, blocking works
```

Pick the blocking test domain out of gravity itself — plain `doubleclick.net` is *not* on
StevenBlack's list (only its subdomains are), so it resolves normally and looks like a failure:

```bash
pihole-FTL sqlite3 /etc/pihole/gravity.db 'select domain from gravity limit 3;'
```

---

## Part 4 — Talos VMs, one root module per host · ~1.5–2 hrs

**Files:** `terraform/modules/proxmox-vm/` (two new inputs), `terraform/hosts/hp-sff-32gb/{image,talos-vms}.tf`,
a whole new `terraform/hosts/hp-sff-16gb/`, plus `outputs.tf` on both.

The cluster spans two machines, but the *VMs* each belong to exactly one. So they're built by the
per-host root modules — `hp-sff-32gb/` gets `cp-1` and `worker-1`, `hp-sff-16gb/` gets `worker-2`
and `worker-3` — and Part 5 bootstraps Talos across all four from a third state.

The pleasant side effect: neither host module needs provider *aliases*. Each has exactly one
Proxmox provider, so `module.proxmox-vm` inherits it with no `providers = {}` block.

### 4.1 Two additions to the module

Talos needs `virtio-scsi-single`, and the module currently hardcodes `agent { enabled = false }` —
which is why `ipv4_addresses` comes back empty in state for the existing VMs. The Talos image
below includes the guest agent extension, so turn it on for these.

📄 **`terraform/modules/proxmox-vm/variables.tf`** — add
```hcl
variable "agent_enabled" {
  description = "Enable the QEMU guest agent. Requires the agent to actually be installed in the guest."
  type        = bool
  default     = false
}

variable "scsi_hardware" {
  description = "SCSI controller model. Talos wants virtio-scsi-single."
  type        = string
  default     = null
}
```

📄 **`terraform/modules/proxmox-vm/main.tf`** — change two things
```bash 
resource "proxmox_virtual_environment_vm" "this" {
  # ...
  scsi_hardware = var.scsi_hardware      # add, next to bios/machine

  agent {
    enabled = var.agent_enabled          # was: false
  }
```

While you're in `variables.tf`, delete the `hostpci_ids` variable (lines 91–94). It's dead — the
refactor replaced it with `hostpci_mappings` and nothing references it any more. And add
`description` to the rest of the inputs; none of them have one.

### 4.2 The Talos image, per host

The two hosts don't share storage, so each downloads its own copy. The schematic ID is computed
once and reused, so both hosts run byte-identical images.

📄 **`terraform/hosts/hp-sff-32gb/image.tf`**
```hcl
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

resource "proxmox_download_file" "talos" {
  content_type            = "iso"
  datastore_id            = "local"          # not local-lvm — this is a file
  node_name               = var.node_name
  file_name               = "talos-${var.talos_version}-homelab.img"
  url                     = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/nocloud-amd64.raw.gz"
  decompression_algorithm = "gz"
  overwrite               = false
}
```

`hp-sff-16gb/image.tf` is identical. The schematic resource is duplicated in both states, which is
fine — it's a pure function of its input, so both compute the same ID.

Add to both `versions.tf`:
```hcl
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.8"
    }
```

> ⚠️ **Everything Talos in Parts 4–5 is unverified.** The `siderolabs/talos` provider has never
> been declared or run in this repo, and it's pre-1.0 with a history of schema churn. When a block
> errors, diff it against the pinned version's registry docs *before* assuming this guide is
> right — the `bpg/proxmox` blocks below are trustworthy because they're running in production on
> the Dell; the Talos ones are not.

### 4.3 The VMs

📄 **`terraform/hosts/hp-sff-32gb/talos-vms.tf`**
```hcl
module "cp_1" {
  source = "../../modules/proxmox-vm"

  name          = "cp-1"
  vm_id         = 610
  node_name     = var.node_name
  datastore     = var.datastore
  cores         = 2
  memory_mb     = 2048
  disk_size_gb  = 20
  disk_image_id = proxmox_download_file.talos.id
  scsi_hardware = "virtio-scsi-single"
  agent_enabled = true
  ipv4_address  = "192.168.0.60/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]
}

module "worker_1" {
  source = "../../modules/proxmox-vm"

  name          = "worker-1"
  vm_id         = 611
  node_name     = var.node_name
  datastore     = var.datastore
  cores         = 4
  memory_mb     = 10240
  disk_size_gb  = 80
  disk_image_id = proxmox_download_file.talos.id
  scsi_hardware = "virtio-scsi-single"
  agent_enabled = true
  ipv4_address  = "192.168.0.61/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]
}
```

`terraform/hosts/hp-sff-16gb/` is a new root module — copy `providers.tf`, `variables.tf` and
`versions.tf` from `hp-sff-32gb/` verbatim (the variable names are already generic: `endpoint`,
`api_token`, `node_name`, `datastore`), change the tfvars, and add `worker-2` (620, 2 cores, 3GB,
30GB, `.62`) and `worker-3` (621, 2 cores, 9GB, 40GB, `.63`) the same way.

📄 **`terraform/hosts/hp-sff-16gb/terraform.tfvars`**
```hcl
endpoint       = "https://192.168.0.125:8006"
api_token      = "terraform@pve!terraform=<uuid>"
node_name      = "hp16"
datastore      = "local-lvm"
ssh_public_key = "ssh-ed25519 AAAA...your-actual-key"
```

hp16 needs the same Proxmox prep as 3.1 — rename, token, SSH key.

### 4.4 Export the nodes

Follow the `outputs.tf` pattern already on the Dell, so the cluster module and Ansible have one
place to read node identities from.

📄 **`terraform/hosts/hp-sff-32gb/outputs.tf`**
```hcl
output "vms" {
  description = "VMs on this node, keyed by name. Consume with: terraform output -json vms"
  value = {
    cp-1     = { vm_id = module.cp_1.vm_id,     name = module.cp_1.name,     ipv4 = module.cp_1.ipv4 }
    worker-1 = { vm_id = module.worker_1.vm_id, name = module.worker_1.name, ipv4 = module.worker_1.ipv4 }
  }
}
```

▶️ **Run, in each host directory in turn:**
```bash
terraform init && terraform apply
```

✅ **Checkpoint:** all four VMs boot and sit at Talos's "waiting for configuration" screen in the
Proxmox console. `talosctl -n 192.168.0.60 --insecure version` answers. They are *not* a cluster
yet — that's Part 5.

---

## Part 5 — Bootstrap Talos · `terraform/clusters/talos/` · ~1–2 hrs

**Files:** `terraform/clusters/talos/{versions,variables,talos,outputs}.tf` + tfvars

The third root module. It owns no VMs — only the cluster's identity: secrets, machine configs,
bootstrap, and the two credential files. Apply it **after** both host modules.

Node IPs arrive as plain variables. They're statically assigned in Part 4, so there's no need to
wire up `terraform_remote_state` — that would add cross-state coupling to move constants around.

📄 **`terraform/clusters/talos/versions.tf`**
```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.8"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}
```

No `proxmox` provider here at all — this module never talks to Proxmox.

📄 **`terraform/clusters/talos/variables.tf`**
```hcl
variable "cluster_name"   { type = string, default = "homelab" }
variable "talos_version"  { type = string, default = "v1.13.5" }
variable "control_plane"  { type = string, default = "192.168.0.60" }

variable "workers" {
  description = "Worker node hostname => IP"
  type        = map(string)
  default = {
    worker-1 = "192.168.0.61"
    worker-2 = "192.168.0.62"
    worker-3 = "192.168.0.63"
  }
}
```

📄 **`terraform/clusters/talos/talos.tf`**
```hcl
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

resource "talos_machine_configuration_apply" "cp_1" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.control_plane
  config_patches = [
    yamlencode({
      machine = {
        network = { hostname = "cp-1" }
        install = { disk = "/dev/sda" }
      }
    })
  ]
}

resource "talos_machine_configuration_apply" "workers" {
  for_each = var.workers

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value
  config_patches = [
    yamlencode({
      machine = {
        network = { hostname = each.key }
        install = { disk = "/dev/sda" }
      }
    })
  ]
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.cp_1]
  node                 = var.control_plane
  endpoint             = var.control_plane
  client_configuration = talos_machine_secrets.this.client_configuration
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = concat([var.control_plane], values(var.workers))
  endpoints            = [var.control_plane]
}

data "talos_cluster_health" "this" {
  depends_on           = [talos_machine_bootstrap.this, talos_machine_configuration_apply.workers]
  client_configuration = data.talos_client_configuration.this.client_configuration
  control_plane_nodes  = [var.control_plane]
  worker_nodes         = values(var.workers)
  endpoints            = [var.control_plane]
  timeouts             = { read = "10m" }
}

data "talos_cluster_kubeconfig" "this" {
  depends_on           = [data.talos_cluster_health.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_plane
  endpoint             = var.control_plane
}
```

Using `for_each` over the worker map rather than three near-identical resource blocks means adding
`worker-4` later is one line in a variable.

📄 **`terraform/clusters/talos/outputs.tf`**
```hcl
resource "local_sensitive_file" "kubeconfig" {
  content         = data.talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/generated/kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/generated/talosconfig"
  file_permission = "0600"
}
```

`generated/` is already covered by `.gitignore`. `talos_machine_secrets` puts the cluster's CA
keys **in state** — which is the real reason `*.tfstate` must never be committed.

▶️ **Run, inside `terraform/clusters/talos/`:**
```bash
terraform init
terraform apply
export KUBECONFIG=$(pwd)/generated/kubeconfig
export TALOSCONFIG=$(pwd)/generated/talosconfig
```

The nodes reboot once during install — `talos_cluster_health` waits for them, so a long pause here
is normal, not a hang.

✅ **Checkpoint:** `kubectl get nodes` shows four nodes `Ready`.
`talosctl -n 192.168.0.60 health` passes.

---

## Part 6 — Cluster bootstrap layer · ~30–60 min

**Files:** `k8s/metallb-pool.yaml`

Straight `kubectl`/`helm` against the live cluster — no Terraform.

### 6.1 Label the nodes

Workloads get pinned to nodes because storage is `local-path` — a pod that reschedules elsewhere
loses its data. The label is what stops that.

▶️ **Run:**
```bash
kubectl label node worker-1 workload=nextcloud
kubectl label node worker-2 workload=git
kubectl label node worker-3 workload=monitoring
```

### 6.2 Storage

▶️ **Run:**
```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

On Talos the provisioner needs a writable host path — `/var/mnt/local-path-provisioner` or
similar under `/var`, since the rest of the filesystem is read-only. Patch the ConfigMap's
`paths` accordingly if pods stay `Pending`.

### 6.3 Namespaces

▶️ **Run:**
```bash
kubectl create ns git
kubectl create ns nextcloud
kubectl create ns monitoring
```

### 6.4 MetalLB

▶️ **Run:**
```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm install metallb metallb/metallb -n metallb-system --create-namespace
```

📄 **`k8s/metallb-pool.yaml`**
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: main
  namespace: metallb-system
spec:
  addresses: ["192.168.0.70-192.168.0.79"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: main
  namespace: metallb-system
spec:
  ipAddressPools: ["main"]
```

▶️ **Run:** `kubectl apply -f k8s/metallb-pool.yaml`

Wait for the webhook to be ready before applying, or the pool is rejected — `kubectl wait
--for=condition=available deploy/metallb-controller -n metallb-system --timeout=120s`.

✅ **Checkpoint:** `kubectl get pods -n metallb-system` all `Running`; `kubectl get storageclass`
shows `local-path (default)`.

---

## Part 7 — Forgejo · ~45–90 min

**Files:** `helm-values/forgejo-values.yaml`, `ansible/playbooks/deploy-apps.yml`

Your git. Self-hosted, on `worker-2`, reachable at `git.home.arpa` (`.71`).

Ansible here never touches an OS — Talos has no SSH. It's just orchestrating `helm` through
`kubernetes.core.helm` against the kubeconfig, so that deployments are recorded in the repo
instead of living in your shell history.

📄 **`helm-values/forgejo-values.yaml`**
```yaml
nodeSelector:
  workload: git

persistence:
  enabled: true
  storageClass: local-path
  size: 20Gi

service:
  http:
    type: LoadBalancer
    loadBalancerIP: 192.168.0.71
  ssh:
    type: LoadBalancer
    loadBalancerIP: 192.168.0.71

gitea:
  config:
    server:
      DOMAIN: git.home.arpa
      ROOT_URL: http://git.home.arpa/
```

Pinning `loadBalancerIP` is what keeps [network-inventory.md](../network-inventory.md) honest.
Forgejo's chart still uses `gitea:` keys for app config — it's a Gitea fork, and that hasn't been
renamed.

📄 **`ansible/playbooks/deploy-apps.yml`**
```yaml
- hosts: localhost
  gather_facts: false
  vars:
    kubeconfig: "{{ playbook_dir }}/../../terraform/clusters/talos/generated/kubeconfig"
  tasks:
    - name: Add chart repos
      kubernetes.core.helm_repository:
        name: "{{ item.name }}"
        repo_url: "{{ item.url }}"
      loop:
        - { name: forgejo,               url: "https://code.forgejo.org/api/packages/forgejo/helm" }
        - { name: nextcloud,             url: "https://nextcloud.github.io/helm/" }
        - { name: prometheus-community,  url: "https://prometheus-community.github.io/helm-charts" }

    - name: Forgejo
      kubernetes.core.helm:
        name: forgejo
        chart_ref: forgejo/forgejo
        release_namespace: git
        values_files: ["{{ playbook_dir }}/../../helm-values/forgejo-values.yaml"]
        kubeconfig: "{{ kubeconfig }}"
```

Parts 8 and 9 add their tasks to this same file.

▶️ **Run:**
```bash
cd ansible
ansible-playbook playbooks/deploy-apps.yml
```

✅ **Checkpoint:** `kubectl get svc -n git` shows `192.168.0.71`; `http://git.home.arpa` loads the
setup page. Create your admin user, then push this homelab repo to it as a first real test:
`git remote add forgejo http://git.home.arpa/<you>/homelab.git && git push forgejo main`.

Keep GitHub as a remote too — a git server that only exists inside the cluster it configures is
another circular dependency. Push to both.

---

## Part 8 — Nextcloud · ~45–90 min

📄 **`helm-values/nextcloud-values.yaml`**
```yaml
nodeSelector:
  workload: nextcloud

nextcloud:
  host: nextcloud.home.arpa
  existingSecret:
    enabled: true
    secretName: nextcloud-admin

persistence:
  enabled: true
  storageClass: local-path
  size: 60Gi

service:
  type: LoadBalancer
  loadBalancerIP: 192.168.0.70

internalDatabase:
  enabled: false
postgresql:
  enabled: true
  primary:
    persistence:
      storageClass: local-path
      size: 8Gi
```

SQLite (the chart's default) will not survive real use — switch to the bundled PostgreSQL now
rather than migrating later. Create the admin secret before deploying, so no password ends up in
a values file:

▶️ **Run:**
```bash
kubectl -n nextcloud create secret generic nextcloud-admin \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password="$(openssl rand -base64 24)"
```

Add to `deploy-apps.yml`:
```yaml
    - name: Nextcloud
      kubernetes.core.helm:
        name: nextcloud
        chart_ref: nextcloud/nextcloud
        release_namespace: nextcloud
        values_files: ["{{ playbook_dir }}/../../helm-values/nextcloud-values.yaml"]
        kubeconfig: "{{ kubeconfig }}"
```

✅ **Checkpoint:** `http://nextcloud.home.arpa` loads and you can log in. If it complains about a
trusted domain, that's `nextcloud.host` not matching the name you used.

---

## Part 9 — Grafana + Prometheus · ~1 hr

📄 **`helm-values/kube-prometheus-stack-values.yaml`**
```yaml
prometheus:
  prometheusSpec:
    nodeSelector:
      workload: monitoring
    retention: 15d
    retentionSize: 8GB
    resources:
      requests: { memory: 2Gi }
      limits:   { memory: 4Gi }
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          resources:
            requests:
              storage: 20Gi

grafana:
  nodeSelector:
    workload: monitoring
  service:
    type: LoadBalancer
    loadBalancerIP: 192.168.0.72
  persistence:
    enabled: true
    storageClassName: local-path
    size: 5Gi

alertmanager:
  enabled: false
```

Note the `nodeSelector`s are nested per-component — a top-level one doesn't reach the operator's
generated StatefulSets, which is the usual reason Prometheus lands on the wrong node.

`retentionSize` alongside `retention` matters here: 15 days of metrics can outgrow the PVC, and
Prometheus handles hitting a size cap gracefully but handles a full disk badly. Alertmanager is
off because there's nowhere to route alerts yet — turn it on when you have somewhere to send them.

**RAM reality check:** hp16 is 16GB, with `worker-2` at 3GB and `worker-3` at 9GB. That leaves
roughly 4GB for Proxmox itself. If it starts swapping, cut Prometheus retention first — it's the
largest and most compressible consumer on that host.

Add to `deploy-apps.yml`:
```yaml
    - name: kube-prometheus-stack
      kubernetes.core.helm:
        name: monitoring
        chart_ref: prometheus-community/kube-prometheus-stack
        release_namespace: monitoring
        values_files: ["{{ playbook_dir }}/../../helm-values/kube-prometheus-stack-values.yaml"]
        kubeconfig: "{{ kubeconfig }}"
```

Talos locks down kubelet metrics endpoints more than most distros, so some of the default
`ServiceMonitor`s (`kube-controller-manager`, `kube-scheduler`, `etcd`) may show as down until
you point them at the right ports. Cosmetic — the node and pod metrics that matter work.

✅ **Checkpoint:** `http://grafana.home.arpa` loads (default login `admin` / `prom-operator` —
change it), and the "Kubernetes / Compute Resources / Cluster" dashboard shows all four nodes.

At this point every service you asked for is running. Parts 10 and 11 wait on hardware.

---

## Part 10 — TrueNAS pool + NFS export 🚧 · blocked on the third drive

The VM is built and TrueNAS is installed ([completed.md](completed.md#truenas)). This is the
storage layer on top, and it needs the third drive to land.

### 10.1 Create the pool

- [ ] **Storage → Create Pool** from the three drives — **RAIDZ1**, giving you the capacity of two
      drives with any one allowed to fail.
- [ ] With 3-disk RAIDZ1, a failed drive must be replaced promptly: during a resilver you have no
      redundancy at all, and resilvering stresses the surviving drives hardest.
- [ ] Schedule a monthly **scrub**. ZFS only finds silent corruption when it looks for it.

### 10.2 Two datasets, one filesystem

- [ ] Create `media` **and** `downloads` as datasets in the same pool.
- [ ] Export the parent (`/mnt/media-pool`) over NFS, restricted to `192.168.0.66` or the LAN.

This matters for Part 11 and is worth understanding before you build it: Sonarr/Radarr "import" a
finished download into the library by **hardlinking**, not copying. A hardlink only works within a
single filesystem. Split them across two, and every import silently becomes a slow full copy, and
you lose the ability to keep seeding the file you just imported. TRaSH Guides calls this an
"atomic move."

✅ **Checkpoint:** `showmount -e 192.168.0.65` lists the export from another machine.

---

## Part 11 — Jellyfin + media stack 🚧 · blocked on Part 10

**Files:** `terraform/hosts/dell/jellyfin.tf`, `ansible/group_vars/jellyfin/vault.yml`,
`ansible/playbooks/jellyfin.yml`

One VM (`jellyfin.home.arpa`, `.66`) running: **Gluetun** (VPN gateway), **qBittorrent**,
**Prowlarr** (indexers), **FlareSolverr** (Cloudflare bypass), **Sonarr**/**Radarr**, and Jellyfin.
Adapted from `codeberg.org/bhoehn/automated-jellyfin-guide` into this repo's module/Ansible pattern.

### 11.1 The VM

📄 **`terraform/hosts/dell/jellyfin.tf`**
```hcl
module "jellyfin" {
  source = "../../modules/proxmox-vm"

  name          = "jellyfin"
  vm_id         = 701
  node_name     = var.dell_node_name
  datastore     = var.dell_datastore
  cores         = 6
  memory_mb     = 10240
  disk_size_gb  = 60
  disk_image_id = proxmox_download_file.ubuntu_cloud_image.id
  ipv4_address  = "192.168.0.66/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]

  user_account = {
    username = "ubuntu"
    password = var.jellyfin_console_password
    keys     = [var.ssh_public_key]
  }
}
```

Reuses the Ubuntu cloud image `images.tf` already downloads for Ollama — no second download. Add
`jellyfin_console_password` to `variables.tf` and the tfvars, and extend `outputs.tf`'s `vms` map.

10GB, not 8: that's six services, and Sonarr/Radarr/Prowlarr are memory-hungry while indexing.
No GPU — a single concurrent viewer means direct play or software transcode is fine, and the one
card in that box is earmarked for Ollama.

**Dell budget after this:** 64 + 16 + 10 = 90GB of 96GB, ~6GB for the host. Tight but workable;
this is the VM to trim first if it isn't.

### 11.2 VPN credentials

▶️ **Run:** `ansible-vault edit ansible/group_vars/jellyfin/vault.yml`
```yaml
vault_vpn_service_provider: "your-provider"
vault_openvpn_user: "your-vpn-username"
vault_openvpn_password: "your-vpn-password"
# vault_wireguard_private_key: "your-key"
# vault_wireguard_addresses: "your-address"
vault_timezone: "Europe/Copenhagen"
```

### 11.3 The stack

📄 **`ansible/playbooks/jellyfin.yml`**
```yaml
- hosts: jellyfin
  become: true
  vars_files:
    - ../group_vars/jellyfin/vault.yml
  tasks:
    - name: Install NFS client + Docker
      apt:
        name: [nfs-common, docker.io, docker-compose-plugin]
        state: present
        update_cache: true

    - name: Mount TrueNAS media pool
      ansible.posix.mount:
        path: /mnt/media-pool
        src: "192.168.0.65:/mnt/media-pool"
        fstype: nfs
        opts: "defaults,_netdev"
        state: mounted

    - name: Write docker-compose for the media stack
      copy:
        dest: /opt/mediastack/docker-compose.yml
        content: |
          services:
            jellyfin:
              image: jellyfin/jellyfin
              network_mode: host
              volumes:
                - /mnt/media-pool/media:/media
                - jellyfin-config:/config

            gluetun:
              image: qmcgaw/gluetun
              container_name: gluetun
              cap_add: [NET_ADMIN]
              devices: ["/dev/net/tun:/dev/net/tun"]
              ports:
                - "8080:8080"   # qbittorrent
                - "9696:9696"   # prowlarr
                - "8191:8191"   # flaresolverr
              volumes:
                - gluetun-config:/gluetun
              environment:
                - VPN_SERVICE_PROVIDER={{ vault_vpn_service_provider }}
                - VPN_TYPE=openvpn
                - OPENVPN_USER={{ vault_openvpn_user }}
                - OPENVPN_PASSWORD={{ vault_openvpn_password }}
                - TZ={{ vault_timezone }}

            qbittorrent:
              image: ghcr.io/linuxserver/qbittorrent
              environment:
                - PUID=1000
                - PGID=1000
                - WEBUI_PORT=8080
                - TZ={{ vault_timezone }}
              volumes:
                - qbittorrent-config:/config
                - /mnt/media-pool/downloads:/downloads
              network_mode: service:gluetun

            prowlarr:
              image: lscr.io/linuxserver/prowlarr:latest
              environment:
                - PUID=1000
                - PGID=1000
                - TZ={{ vault_timezone }}
              volumes:
                - prowlarr-config:/config
              network_mode: service:gluetun

            flaresolverr:
              image: ghcr.io/flaresolverr/flaresolverr:latest
              environment:
                - TZ={{ vault_timezone }}
              network_mode: service:gluetun

            sonarr:
              image: ghcr.io/linuxserver/sonarr
              environment:
                - PUID=1000
                - PGID=1000
                - TZ={{ vault_timezone }}
              volumes:
                - sonarr-config:/config
                - /mnt/media-pool/media/tv:/tv
                - /mnt/media-pool/downloads:/downloads
              ports: ["8989:8989"]

            radarr:
              image: ghcr.io/linuxserver/radarr
              environment:
                - PUID=1000
                - PGID=1000
                - TZ={{ vault_timezone }}
              volumes:
                - radarr-config:/config
                - /mnt/media-pool/media/movies:/movies
                - /mnt/media-pool/downloads:/downloads
              ports: ["7878:7878"]

          volumes:
            jellyfin-config:
            gluetun-config:
            qbittorrent-config:
            prowlarr-config:
            sonarr-config:
            radarr-config:

    - name: Bring it up
      community.docker.docker_compose_v2:
        project_src: /opt/mediastack
```

qBittorrent, Prowlarr and FlareSolverr share Gluetun's network namespace
(`network_mode: service:gluetun`), so their traffic physically cannot bypass the VPN — if Gluetun
dies, they lose networking entirely rather than leaking. Sonarr/Radarr/Jellyfin don't need that,
so they're on the normal bridge.

Add a `jellyfin` group to `ansible/inventory.yml` with `ansible_host: 192.168.0.66` and
`ansible_user: ubuntu`.

### 11.4 Wiring it up (manual, one-time, per web UI)

**The addressing gotcha:** qBittorrent/Prowlarr/FlareSolverr live in Gluetun's namespace, separate
from Sonarr/Radarr's. When Sonarr or Radarr ask how to reach qBittorrent, give them the VM's own
IP — **`192.168.0.66`** — never `localhost`. Inside a container, `localhost` means that container.

- [ ] **Jellyfin** (`:8096`) — setup wizard, libraries at `/media/tv` and `/media/movies`.
- [ ] **qBittorrent** (`:8080`) — first-run password from `docker logs qbittorrent`, then change it.
      Save path `/downloads/complete`, incomplete `/downloads/incomplete`. Under Advanced set
      **Network Interface to `tun0`**, not "Any" — that's what actually enforces VPN-only traffic.
- [ ] **Prowlarr** (`:9696`) — add indexers; point Cloudflare-protected ones at FlareSolverr on
      `192.168.0.66:8191`.
- [ ] **Sonarr** (`:8989`) / **Radarr** (`:7878`) — add qBittorrent as download client at
      `192.168.0.66:8080`; root folder `/tv` or `/movies`; build a quality profile; then connect
      both to Prowlarr with their API keys so indexers sync automatically.

✅ **Checkpoint:** a manual search in Sonarr returns indexer results, and sending one to
qBittorrent downloads it with the VPN's source IP — not your ISP's.

**Optional later:** Bazarr (subtitles), Homepage (dashboard), Seerr (requests), Caddy or
nginx-proxy-manager (TLS). Skip MergerFS from the source guide — ZFS already solves that problem
one layer down.

---

## Part 12 — Backups and wiring · ~2 hrs, do not skip

- [ ] Router DHCP → DNS server `192.168.0.64`, so the whole LAN uses Pi-hole and `home.arpa`.
- [ ] `vzdump` schedules on all three hosts, to an external target — the 5TB USB drive, or the
      TrueNAS pool for the two HP hosts (**not** for the Dell: a backup of a VM stored on a VM
      running on the same host is not a backup).
- [ ] `talosctl etcd snapshot` on a cron, stored off-box. This is the cluster. Everything else is
      re-runnable Terraform; etcd is not.
- [ ] **TrueNAS caveat:** `vzdump` on the TrueNAS VM captures its boot disk, not the ZFS pool.
      RAIDZ1 covers drive failure; scrubs cover corruption; neither covers "deleted the dataset."
      Snapshot the datasets separately.
- [ ] **Restore one thing, once.** An untested backup is a hope, not a plan.
- [ ] Rebuild test: `cd terraform/clusters/talos && terraform destroy && terraform apply`, then
      re-apply the host modules. Pi-hole and the Dell live in different states and stay untouched —
      which is the actual proof your cluster IaC is complete on its own.

---

## Side quest — Kubernetes the hard way

Everything above hands cluster construction to Talos and Terraform. To understand what's being
hidden, build one by hand: [kubernetes-the-hard-way.md](kubernetes-the-hard-way.md) — four
throwaway Ubuntu VMs on hp32, in their own Terraform state so destroying them can't touch anything
real.

---

## Later — GPU passthrough for Ollama

The RTX 4000 is still on the host. Adding it to the Ollama VM is much less painful than the
original notes suggested, because the Dell already proves the pattern with the TrueNAS HBA:

1. **Datacenter → Resource Mappings → PCI Devices** — create a mapping named `ollama-gpu` for the
   card. Referring to it by name means a PCI renumber after a hardware change doesn't break
   Terraform, and it's what an API token is permitted to use.
2. On the host, blacklist `nouveau`/`nvidia` and bind the card to `vfio-pci`, then reboot.
3. One line in `terraform/hosts/dell/vms.tf`: `hostpci_mappings = ["ollama-gpu"]` on
   `module.ollama`. That's it — the module's `dynamic "hostpci"` block handles the rest.
4. Extend `ansible/playbooks/ollama.yml` with `nvidia-container-toolkit` and a
   `deploy.resources.reservations.devices` GPU block in the compose file.

The VM must be stopped for the passthrough to attach, so expect a restart.

**Also still deferred:** a third control-plane node for real HA (a single `cp-1` means cluster
downtime whenever hp32 reboots), Longhorn or Ceph to replace `local-path` and its node-pinning,
ingress + cert-manager for real TLS instead of bare LoadBalancer IPs, and GitOps once Forgejo is
holding this repo.
