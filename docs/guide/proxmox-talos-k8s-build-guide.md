# Proxmox + Talos Kubernetes — build guide

Work top to bottom. Each part opens with **the files you'll create**, then walks through them. Two markers used throughout:

- 📄 **File** — content to save at that path. Create it, don't run it.
- ▶️ **Run** — a command to type in your terminal, not something to save.

Uses `terraform` (not `tofu` — swap the binary name if you switch later, syntax is identical). Each part ends with a **✅ Checkpoint** — don't move on until it passes.

Ordered to build **Ollama first** — the TrueNAS disks (4x SAS behind an LSI 9240-8i) haven't arrived yet, and Ollama has no dependency on TrueNAS or anything else.

## Before you start

**On your workstation**, install: `terraform`, `kubectl`, `talosctl`, `helm`, and `ansible` with the collections this guide uses:
```bash
ansible-galaxy collection install kubernetes.core community.docker ansible.posix
```
Generate an SSH key if you don't have one: `ssh-keygen -t ed25519`.

**Repo skeleton** — create these empty folders now, you'll fill them in as you go:
```bash
mkdir -p homelab-k8s/{terraform-dell,terraform-pihole,terraform,ansible/playbooks,helm-values,k8s}
cd homelab-k8s
```
```
homelab-k8s/
├── terraform-dell/     # ollama, truenas (later), jellyfin (later)
├── terraform-pihole/   # Pi-hole LXC
├── terraform/          # Talos cluster
├── ansible/
│   └── playbooks/
├── helm-values/
└── k8s/
```
Every `terraform-*` folder here is its own independent state — you `terraform init` and `apply` inside each one separately, they never touch each other.

**Add a `.gitignore`** if this is going in git — `*.tfvars`, `.terraform/`, `*.tfstate*`, `generated/` all contain secrets or machine-specific junk that shouldn't be committed:

📄 **`.gitignore`**
```
*.tfvars
.terraform/
*.tfstate
*.tfstate.backup
generated/
```

**Network plan** — confirmed subnet, `192.168.0.0/24`:

| Name | IP |
|---|---|
| `ollama` | 192.168.0.67 |
| `truenas` | 192.168.0.65 |
| `jellyfin` | 192.168.0.66 |
| `pihole` | 192.168.0.64 |
| `cp-1` | 192.168.0.60 |
| `worker-1` (Nextcloud) | 192.168.0.61 |
| `worker-2` (Git) | 192.168.0.62 |
| `worker-3` (Grafana+Prometheus) | 192.168.0.63 |
| MetalLB pool | 192.168.0.70–79 |

Gateway `192.168.0.1` — confirm this is actually your router's address. Provider versions used throughout: `bpg/proxmox ~> 0.111`, `siderolabs/talos ~> 0.8`. Both are pre-1.0 — if a block below errors, diff it against the pinned version's registry docs before assuming the guide is wrong.

**Dell RAM budget: 96GB total.** Steady-state split once everything's built: `ollama` 64GB, `truenas` 16GB, `jellyfin` (media stack) 10GB, ~6GB left for the Proxmox host itself — see Part 4 for why it's 10GB, not the more obvious-looking 8.

**Ordering note:** the Dell VMs are configured to use Pi-hole (`192.168.0.64`) as primary DNS even though Pi-hole doesn't exist yet at this point in the guide — that's fine, they fall through to the router (`.1`) until Part 5 stands Pi-hole up.

---

## Part 1 — Dell: host prep · ~20–30 min

**Files you'll create:** `terraform-dell/versions.tf`, `terraform-dell/providers.tf`, `terraform-dell/variables.tf`

No `terraform apply` yet — this part is prep plus laying the project skeleton.

### 1.1 Rename the host
- [ ] No GUI option for this — it's CLI. On the Dell: edit `/etc/hosts` with its real LAN IP mapped to the new name, `hostnamectl set-hostname dell`, restart `pve-cluster`/`pvedaemon`/`pveproxy` (or just reboot), `pvecm updatecerts -f` to fix the SSL cert, verify in the web UI.
- [ ] Do this now, before any VMs exist — Proxmox's own docs say renames should happen on an empty node.
- [ ] If you use Avahi/`.local` names to reach the host, restart `avahi-daemon` (or reboot) afterward — it won't advertise the new name until it does.

### 1.2 BIOS / IOMMU
- [ ] Enable VT-d in BIOS (Xeon W-2245 is Intel — look for "VT-d" or "Intel Virtualization Technology for Directed I/O"). This is what a future GPU passthrough for `ollama` will need — worth doing now while you're in the BIOS anyway.
- [ ] Add `intel_iommu=on iommu=pt` to `/etc/default/grub`'s `GRUB_CMDLINE_LINUX_DEFAULT`, then `update-grub` and reboot.
- [ ] Confirm: `dmesg | grep -e DMAR -e IOMMU` shows IOMMU groups.

### 1.3 Terraform project skeleton

📄 **`terraform-dell/versions.tf`**
```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}
```

📄 **`terraform-dell/providers.tf`**
```hcl
provider "proxmox" {
  endpoint = var.dell_endpoint
  insecure = true
  username = "root@pam"
  password = var.dell_root_password
}
```
Root user/password, not an API token — `hostpci` passthrough (GPU on `ollama` later, HBA on `truenas` once the disks arrive) isn't compatible with token auth. That's different from the other two hosts, which use scoped tokens starting in Part 5.

📄 **`terraform-dell/variables.tf`**
```hcl
variable "dell_endpoint"      { type = string }
variable "dell_root_password" { type = string, sensitive = true }
variable "dell_node_name"     { type = string, default = "dell" }
variable "dell_datastore"     { type = string, default = "local-lvm" }
variable "ssh_public_key"     { type = string }
```

You'll write `terraform.tfvars` (the actual values) in Part 2, right before the first `apply` — no point filling it in before there's a resource to apply it to.

---

## Part 2 — Dell: Ollama · ~30–60 min

**Files you'll create:** `terraform-dell/ollama.tf`, `terraform-dell/terraform.tfvars`, `ansible/playbooks/configure-ollama.yml`

### 2.1 The VM

📄 **`terraform-dell/ollama.tf`**
```hcl
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = var.dell_datastore
  node_name    = var.dell_node_name
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_vm" "ollama" {
  name      = "ollama"
  node_name = var.dell_node_name
  vm_id     = 702
  bios      = "ovmf"
  machine   = "q35"

  cpu    { cores = 6, type = "host" }
  memory { dedicated = 65536 }   # 64GB — see sizing note below

  efi_disk { datastore_id = var.dell_datastore, file_format = "raw", type = "4m" }

  disk {
    datastore_id = var.dell_datastore
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "scsi0"
    size         = 80
  }

  # GPU passthrough lands here eventually — commented out for the first pass.
  # Base VM stable first, then vfio-pci host prep, then fill in the real PCI ID.
  # hostpci {
  #   device = "hostpci0"
  #   id     = "0000:03:00"   # from `lspci | grep -i nvidia`
  #   pcie   = true
  #   xvga   = true
  # }

  network_device { bridge = "vmbr0" }
  agent { enabled = true }

  initialization {
    datastore_id = var.dell_datastore
    ip_config { ipv4 { address = "192.168.0.67/24", gateway = "192.168.0.1" } }
    dns { servers = ["192.168.0.64", "192.168.0.1"] }
    user_account { keys = [var.ssh_public_key] }
  }
}
```

**Sizing note:** no ceiling on Ollama's side — 64GB was chosen to leave `truenas` (16GB) + `jellyfin`'s media stack (10GB) + ~6GB host overhead comfortable once those exist, out of 96GB total. Roughly what that buys you:

| Model size | Quantization | Approx. RAM needed |
|---|---|---|
| 13B | Q4 | ~7–8GB |
| 30B | Q4 | ~17–19GB |
| 70B | Q4 | ~38–40GB |
| 70B | Q5/Q6 | ~48–58GB |

64GB fits a 70B model at Q4 with headroom for context/KV cache.

### 2.2 Fill in the variables and apply

📄 **`terraform-dell/terraform.tfvars`**
```hcl
dell_endpoint      = "https://192.168.0.254:8006"
dell_root_password = "your-actual-root-password"
dell_node_name     = "dell"
dell_datastore     = "local-lvm"
ssh_public_key     = "ssh-ed25519 AAAA...your-actual-key"
```

▶️ **Run, inside `terraform-dell/`:**
```bash
terraform init
terraform apply
```

### 2.3 Install Ollama on it

📄 **`ansible/playbooks/configure-ollama.yml`**
```yaml
- hosts: ollama
  become: true
  tasks:
    - name: Install Docker
      apt:
        name: [docker.io, docker-compose-plugin]
        state: present
        update_cache: true

    - name: Write docker-compose for Ollama
      copy:
        dest: /opt/ollama/docker-compose.yml
        content: |
          services:
            ollama:
              image: ollama/ollama
              ports: ["11434:11434"]
              volumes: ["ollama-data:/root/.ollama"]
          volumes:
            ollama-data:

    - name: Bring it up
      community.docker.docker_compose_v2:
        project_src: /opt/ollama
```
You'll also need a minimal `ansible/inventory.yml` with an `ollama` group pointing at `192.168.0.67` — the full inventory gets built out across Parts 2–5, add groups as you go.

▶️ **Run, from the repo root:**
```bash
ansible-playbook ansible/playbooks/configure-ollama.yml
```

✅ **Checkpoint:** `curl 192.168.0.67:11434` responds; `docker exec -it ollama ollama run llama3` (or your model of choice) gives you a prompt.

---

## Part 3 — Dell: TrueNAS · once the SAS disks + LSI 9240-8i arrive · ~2–4 hrs

**Files you'll create:** `terraform-dell/truenas.tf` (same `terraform-dell/` project as Part 2 — no new `init`, it's already initialized)

Skip this and Part 4 until the hardware's in hand.

**Heads-up on the 9240-8i:** it's a hardware RAID card by default (MegaRAID/IR firmware), which fights ZFS — ZFS wants raw, unabstracted access to each disk. Cross-flash it to **IT-mode firmware** first (it shares the LSI SAS2008 chipset with the 9211-8i, so 9211-8i IT firmware applies). Occasionally a chip revision mismatch complicates the flash — if that happens, search "crossflash 9240-8i chip revision" for the current workaround. Do this before passing the card through, not after.

### 3.1 Once the card's installed and cross-flashed
- [ ] Find its PCI ID: `lspci | grep -i sas`.
- [ ] Drives sharing the onboard controller with the boot drive instead? Skip to 3.3's "no dedicated HBA" section.

### 3.2 The VM

📄 **`terraform-dell/truenas.tf`**
```hcl
resource "proxmox_virtual_environment_download_file" "truenas_iso" {
  content_type = "iso"
  datastore_id = var.dell_datastore
  node_name    = var.dell_node_name
  url          = "https://download.truenas.com/TrueNAS-SCALE-<version>/TrueNAS-SCALE-<version>.iso"
  # get the current filename from truenas.com/download-truenas-scale
}

resource "proxmox_virtual_environment_vm" "truenas" {
  name      = "truenas"
  node_name = var.dell_node_name
  vm_id     = 700
  bios      = "ovmf"
  machine   = "q35"

  cpu    { cores = 4, type = "host" }
  memory { dedicated = 16384 }

  efi_disk { datastore_id = var.dell_datastore, file_format = "raw", type = "4m" }

  disk {                     # TrueNAS's own boot disk — NOT the media pool
    datastore_id = var.dell_datastore
    interface    = "scsi0"
    size         = 32
  }

  cdrom      { file_id = proxmox_virtual_environment_download_file.truenas_iso.id }
  boot_order = ["ide2", "scsi0"]

  hostpci {   # the whole HBA, now in IT mode from 3.1
    device = "hostpci0"
    id     = "0000:0a:00"    # replace with your controller's ID from lspci
    pcie   = true
  }

  network_device { bridge = "vmbr0" }
  initialization {
    datastore_id = var.dell_datastore
    ip_config { ipv4 { address = "192.168.0.65/24", gateway = "192.168.0.1" } }
    dns { servers = ["192.168.0.64", "192.168.0.1"] }
  }
}
```

▶️ **Run, inside `terraform-dell/`:**
```bash
terraform apply
```

**No dedicated HBA?** Drop the `hostpci` block. The bpg provider's `disk` block doesn't support raw physical devices — pass the 4 disks through individually instead, as a manual one-time step after the VM exists:
```bash
qm set 700 -scsi1 /dev/disk/by-id/<disk1-id> \
           -scsi2 /dev/disk/by-id/<disk2-id> \
           -scsi3 /dev/disk/by-id/<disk3-id> \
           -scsi4 /dev/disk/by-id/<disk4-id>
```
Use `/dev/disk/by-id/...` paths, never `/dev/sdX` — those renumber across reboots. Shouldn't apply to your setup since the 9240-8i is dedicated, but here in case the cross-flash doesn't go cleanly.

### 3.3 Install TrueNAS (manual — no unattended path here)
- [ ] Boot the console, click through the installer onto the 32GB boot disk
- [ ] In the web UI, create a pool from the 4 passed-through drives — **RAIDZ1** is the sensible default for 4 disks; a pair of mirrors gives faster resilvers at less usable capacity if you'd rather have that
- [ ] Create a second dataset, `downloads`, alongside `media`, in the same pool — Part 4's automated download stack needs both on the same filesystem to hardlink instead of copy
- [ ] Export the parent (`/mnt/media-pool`, covering both `media` and `downloads`) via NFS, restricted to `192.168.0.66` (`jellyfin`) or the LAN subnet

✅ **Checkpoint:** from another machine, `showmount -e 192.168.0.65` lists the export.

---

## Part 4 — Dell: Jellyfin + automated media stack · after Part 3 · ~2.5–3.5 hrs

**Files you'll create:** `terraform-dell/jellyfin.tf`, `ansible/group_vars/jellyfin/vault.yml`, `ansible/playbooks/configure-jellyfin.yml`

Same VM (`jellyfin`, `192.168.0.66`) as before, now running the fuller stack: **Gluetun** (VPN gateway container), **qBittorrent** (torrent client, routed through Gluetun only), **Prowlarr** (indexer manager), **FlareSolverr** (Cloudflare bypass for indexers that need it), **Sonarr**/**Radarr** (TV/movie automation), plus Jellyfin itself. Adapted from the workflow at `codeberg.org/bhoehn/automated-jellyfin-guide` into this guide's Terraform/Ansible/NFS pattern.

### 4.1 Why Part 3 exports two datasets, not one

Part 3 has you export both `media` and `downloads` from the same TrueNAS pool, not just `media`. That's for this part: Sonarr/Radarr "import" finished downloads into the library via a hardlink, not a copy — that only works when the download and the library live on the same filesystem. Different filesystems means every import silently becomes a slow full copy instead, and you lose the ability to keep seeding after import. This is what TRaSH Guides (linked in the source) calls an "atomic move."

### 4.2 The VM

📄 **`terraform-dell/jellyfin.tf`**
```hcl
resource "proxmox_virtual_environment_vm" "jellyfin" {
  name      = "jellyfin"
  node_name = var.dell_node_name
  vm_id     = 701
  bios      = "ovmf"
  machine   = "q35"

  cpu    { cores = 6, type = "host" }
  memory { dedicated = 10240 }   # 10GB — six services now, not one; see RAM budget note below

  efi_disk { datastore_id = var.dell_datastore, file_format = "raw", type = "4m" }

  disk {
    datastore_id = var.dell_datastore
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id   # defined in ollama.tf
    interface    = "scsi0"
    size         = 60
  }

  network_device { bridge = "vmbr0" }
  agent { enabled = true }

  initialization {
    datastore_id = var.dell_datastore
    ip_config { ipv4 { address = "192.168.0.66/24", gateway = "192.168.0.1" } }
    dns { servers = ["192.168.0.64", "192.168.0.1"] }
    user_account { keys = [var.ssh_public_key] }
  }
}
```
No GPU here — single concurrent viewer means software transcoding (or direct play) is fine, and the one card in this box goes to `ollama` instead.

**Dell RAM budget, updated:** `ollama` 64GB + `truenas` 16GB + `jellyfin` 10GB = 90GB of 96GB, ~6GB left for the Proxmox host — tighter than before but still workable. If it's not enough once Prowlarr/Sonarr/Radarr are all indexing actively, this is the VM to bump first.

▶️ **Run, inside `terraform-dell/`:**
```bash
terraform apply
```

### 4.3 VPN credentials (secrets — vault these, don't commit them)
Gluetun needs your VPN provider's credentials. Pick OpenVPN or WireGuard depending on what your provider supports; both are shown below, comment out whichever you're not using. `ansible-vault edit ansible/group_vars/jellyfin/vault.yml` and add:
```yaml
vault_vpn_service_provider: "your-provider"   # see Gluetun's supported-providers list
vault_openvpn_user: "your-vpn-username"
vault_openvpn_password: "your-vpn-password"
# vault_wireguard_private_key: "your-key"
# vault_wireguard_addresses: "your-address"
vault_timezone: "America/New_York"            # replace with your own
```

### 4.4 Install everything

📄 **`ansible/playbooks/configure-jellyfin.yml`**
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

    - name: Mount TrueNAS media pool (media + downloads, same filesystem)
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
                # - WIREGUARD_PRIVATE_KEY={{ vault_wireguard_private_key }}
                # - WIREGUARD_ADDRESSES={{ vault_wireguard_addresses }}
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
              image: lscr.io/linuxserver/prowlarr:develop
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
                - PUID=1000
                - PGID=1000
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
Same pattern as the source guide's `docker-compose.yml`, translated into Ansible so it's provisioned the same way as everything else in this build — qBittorrent, Prowlarr, and FlareSolverr all route through Gluetun's network namespace (`network_mode: service:gluetun`) so their traffic can't bypass the VPN; Sonarr/Radarr/Jellyfin don't need to, so they're not.

▶️ **Run:**
```bash
ansible-playbook ansible/playbooks/configure-jellyfin.yml
```

### 4.5 Configure it (manual, one-time, in each web UI)

**Cross-service addressing note, since it trips people up:** qBittorrent/Prowlarr/FlareSolverr live inside Gluetun's network namespace, separate from Sonarr/Radarr's. When Sonarr or Radarr ask for a host/IP to reach qBittorrent or Prowlarr, use the VM's own IP — **`192.168.0.66`** — not `localhost`. `localhost` inside a container means that container, not the host.

- [ ] **Jellyfin** (`192.168.0.66:8096`) — run the setup wizard, add libraries pointing at `/media/tv` and `/media/movies`.
- [ ] **qBittorrent** (`192.168.0.66:8080`) — get the auto-generated first-run password with `docker logs qbittorrent`, then change username/password under Tools → Options → WebUI. Set default save path to `/downloads/complete`, enable "keep incomplete torrents in" → `/downloads/incomplete`. Under Advanced, set Network Interface to the VPN's tunnel interface (usually `tun0`), not "Any" — this is what actually enforces VPN-only downloading.
- [ ] **Prowlarr** (`192.168.0.66:9696`) — add your indexers (Prowlarr's own quick-start guide covers this well). For any indexer needing Cloudflare bypass, point it at FlareSolverr on `192.168.0.66:8191`.
- [ ] **Sonarr** (`192.168.0.66:8989`) / **Radarr** (`192.168.0.66:7878`), same steps for each:
  - Add qBittorrent as a download client, host `192.168.0.66`, port `8080`, your qBittorrent credentials.
  - Settings → Media Management → Add Root Folder: `/tv` (Sonarr) or `/movies` (Radarr).
  - Settings → Profiles: build a quality profile (check the resolutions you want, e.g. cap at Bluray-1080p to save space; optionally enable "Upgrades Allowed" with an upgrade-until ceiling).
  - Optional: enable file renaming under Media Management for a consistently organized library.
  - Under the Sonarr/Radarr section of Prowlarr's settings, connect each app with its API key (Settings → General in Sonarr/Radarr) so Prowlarr pushes indexers to both automatically.

✅ **Checkpoint:** a manual search in Sonarr or Radarr returns results from your indexers, and sending one to qBittorrent shows it downloading through the VPN interface (check the source IP in qBittorrent's connection status — it should be the VPN's, not your ISP's).

**Not covered here, optional add-ons from the same stack if you want them later:** Bazarr (subtitles), Homepage (dashboard), jfa-go or Wizzarr (user invites/self-signup for Jellyfin), Seerr (request management), Caddy or nginx-proxy-manager (reverse proxy with TLS). You don't need MergerFS from the source guide's "Advanced Configuration" section — TrueNAS's ZFS pool already solves the same multiple-drives problem at the storage layer, so that part doesn't apply to this setup.

Dell's done at this point. Everything from here is the separate k8s side (32GB + 16GB hosts).

---

## Part 5 — Pi-hole (32GB host) · ~1–1.5 hrs

**Files you'll create:** `terraform-pihole/versions.tf`, `terraform-pihole/providers.tf`, `terraform-pihole/variables.tf`, `terraform-pihole/pihole.tf`, `terraform-pihole/terraform.tfvars`, `ansible/playbooks/configure-pihole.yml`

Do this first on the k8s side — the cluster VMs point at it for DNS from first boot.

### 5.1 Proxmox prep
- [ ] Rename the host if it's still the default `pve` — same procedure as Part 1.1, before creating any VMs.
- [ ] **Datacenter → Permissions → API Tokens** — create `terraform@pve`, role with `VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`, `Datastore.AllocateSpace`, `Datastore.Audit`, `Sys.Modify` on `/`
- [ ] Confirm the storage name (`local-lvm` is Proxmox's default)
- [ ] Enable SSH key auth for that user — the provider uploads images via SCP, not just the API

This host uses a scoped API token, not root/password — no PCI passthrough here, unlike the Dell.

### 5.2 Terraform project

📄 **`terraform-pihole/versions.tf`**
```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}
```

📄 **`terraform-pihole/providers.tf`**
```hcl
provider "proxmox" {
  endpoint  = var.host_a_endpoint
  insecure  = true
  api_token = var.host_a_api_token
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}
```

📄 **`terraform-pihole/variables.tf`**
```hcl
variable "host_a_endpoint"  { type = string }
variable "host_a_api_token" { type = string, sensitive = true }
variable "host_a_node_name" { type = string, default = "pve-a" }
variable "host_a_datastore" { type = string, default = "local-lvm" }
variable "proxmox_ssh_user" { type = string, default = "root" }
variable "ssh_public_key"   { type = string }
```

📄 **`terraform-pihole/pihole.tf`**
```hcl
resource "proxmox_virtual_environment_download_file" "debian_lxc_template" {
  content_type = "vztmpl"
  datastore_id = var.host_a_datastore
  node_name    = var.host_a_node_name
  url          = "http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
  # exact filename/version drifts — run `pveam available` on the host and match it
}

resource "proxmox_virtual_environment_container" "pihole" {
  node_name    = var.host_a_node_name
  vm_id        = 640
  unprivileged = true
  started      = true

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.debian_lxc_template.id
    type              = "debian"
  }

  cpu    { cores = 1 }
  memory { dedicated = 1024 }
  disk   { datastore_id = var.host_a_datastore, size = 4 }

  network_interface { name = "eth0", bridge = "vmbr0" }

  initialization {
    hostname = "pihole"
    ip_config { ipv4 { address = "192.168.0.64/24", gateway = "192.168.0.1" } }
    user_account { keys = [var.ssh_public_key] }
  }
}
```

📄 **`terraform-pihole/terraform.tfvars`**
```hcl
host_a_endpoint  = "https://<32gb-host-ip>:8006"
host_a_api_token = "terraform@pve!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
host_a_node_name = "pve-a"
host_a_datastore = "local-lvm"
ssh_public_key   = "ssh-ed25519 AAAA...your-actual-key"
```

▶️ **Run, inside `terraform-pihole/`:**
```bash
terraform init
terraform apply
```

### 5.3 Install Pi-hole

📄 **`ansible/playbooks/configure-pihole.yml`**
```yaml
- hosts: pihole
  become: true
  vars:
    pihole_webpassword: "{{ vault_pihole_webpassword }}"   # ansible-vault this
  environment:
    PIHOLE_INTERFACE: eth0
    IPV4_ADDRESS: "192.168.0.64/24"
    PIHOLE_DNS_1: "1.1.1.1"
    PIHOLE_DNS_2: "9.9.9.9"
    WEBPASSWORD: "{{ pihole_webpassword }}"
  tasks:
    - name: Install Pi-hole unattended
      shell: curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
      args:
        creates: /etc/pihole/setupVars.conf
```
Add a `pihole` group to `ansible/inventory.yml` (`ansible_host: 192.168.0.64`) alongside the `ollama`/`jellyfin` groups from earlier parts.

▶️ **Run:**
```bash
ansible-playbook ansible/playbooks/configure-pihole.yml
```

✅ **Checkpoint:** `dig @192.168.0.64 google.com` returns an answer.

---

## Part 6 — Talos Kubernetes cluster (32GB + 16GB hosts) · ~4–6 hrs first time

**Files you'll create:** `terraform/versions.tf`, `terraform/providers.tf`, `terraform/variables.tf`, `terraform/image.tf`, `terraform/vms.tf`, `terraform/talos.tf`, `terraform/outputs.tf`, `terraform/terraform.tfvars`

The slow part is debugging schema drift on pre-1.0 providers, not the `apply` itself.

### 6.1 Proxmox prep on the 16GB host
Same as 5.1 — rename to `pve-b`, create its own API token, confirm storage, enable SSH key auth.

### 6.2 Provider config, two aliases (standalone hosts, not clustered)

📄 **`terraform/versions.tf`**
```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
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

📄 **`terraform/providers.tf`**
```hcl
provider "proxmox" {
  alias     = "host_a"          # 32GB host
  endpoint  = var.host_a_endpoint
  insecure  = true
  api_token = var.host_a_api_token
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}

provider "proxmox" {
  alias     = "host_b"          # 16GB host
  endpoint  = var.host_b_endpoint
  insecure  = true
  api_token = var.host_b_api_token
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}
```

📄 **`terraform/variables.tf`**
```hcl
variable "host_a_endpoint"   { type = string }
variable "host_a_api_token"  { type = string, sensitive = true }
variable "host_a_node_name"  { type = string, default = "pve-a" }
variable "host_a_datastore"  { type = string, default = "local-lvm" }

variable "host_b_endpoint"   { type = string }
variable "host_b_api_token"  { type = string, sensitive = true }
variable "host_b_node_name"  { type = string, default = "pve-b" }
variable "host_b_datastore"  { type = string, default = "local-lvm" }

variable "proxmox_ssh_user"  { type = string, default = "root" }
variable "talos_version"     { type = string, default = "v1.13.5" }
variable "cluster_name"      { type = string, default = "homelab" }
variable "cluster_vip"       { type = string, default = "192.168.0.60" } # cp-1 IP, single-CP for now
```

### 6.3 Talos image — downloaded to each host's local storage since it isn't shared

📄 **`terraform/image.tf`**
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

resource "proxmox_virtual_environment_download_file" "talos_host_a" {
  provider                = proxmox.host_a
  content_type            = "iso"
  datastore_id            = var.host_a_datastore
  node_name                = var.host_a_node_name
  file_name                = "talos-${var.talos_version}-homelab.img"
  url                      = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/nocloud-amd64.raw.gz"
  decompression_algorithm  = "gz"
  overwrite                 = false
}

resource "proxmox_virtual_environment_download_file" "talos_host_b" {
  provider                = proxmox.host_b
  content_type            = "iso"
  datastore_id            = var.host_b_datastore
  node_name                = var.host_b_node_name
  file_name                = "talos-${var.talos_version}-homelab.img"
  url                      = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/nocloud-amd64.raw.gz"
  decompression_algorithm  = "gz"
  overwrite                 = false
}
```

### 6.4 The 4 VMs — UEFI + q35 (Talos's recommendation on Proxmox)

📄 **`terraform/vms.tf`** — full for `cp-1`, `worker-1`, `worker-2`; `worker-3` follows the same shape:
```hcl
resource "proxmox_virtual_environment_vm" "cp_1" {
  provider      = proxmox.host_a
  name          = "cp-1"
  node_name     = var.host_a_node_name
  vm_id         = 610
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  cpu    { cores = 2, type = "host" }
  memory { dedicated = 2048 }

  efi_disk {
    datastore_id = var.host_a_datastore
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = var.host_a_datastore
    file_id      = proxmox_virtual_environment_download_file.talos_host_a.id
    interface    = "scsi0"
    size         = 20
  }

  network_device { bridge = "vmbr0" }
  agent { enabled = true }

  initialization {
    datastore_id = var.host_a_datastore
    ip_config {
      ipv4 { address = "192.168.0.60/24", gateway = "192.168.0.1" }
    }
    dns { servers = ["192.168.0.64", "192.168.0.1"] }
  }
}

resource "proxmox_virtual_environment_vm" "worker_1" {
  provider      = proxmox.host_a
  name          = "worker-1"
  node_name     = var.host_a_node_name
  vm_id         = 611
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  cpu    { cores = 4, type = "host" }
  memory { dedicated = 10240 }

  efi_disk { datastore_id = var.host_a_datastore, file_format = "raw", type = "4m" }

  disk {
    datastore_id = var.host_a_datastore
    file_id      = proxmox_virtual_environment_download_file.talos_host_a.id
    interface    = "scsi0"
    size         = 80
  }

  network_device { bridge = "vmbr0" }
  agent { enabled = true }

  initialization {
    datastore_id = var.host_a_datastore
    ip_config { ipv4 { address = "192.168.0.61/24", gateway = "192.168.0.1" } }
    dns { servers = ["192.168.0.64", "192.168.0.1"] }
  }
}

resource "proxmox_virtual_environment_vm" "worker_2" {
  provider      = proxmox.host_b
  name          = "worker-2"
  node_name     = var.host_b_node_name
  vm_id         = 620
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  cpu    { cores = 2, type = "host" }
  memory { dedicated = 3072 }

  efi_disk { datastore_id = var.host_b_datastore, file_format = "raw", type = "4m" }

  disk {
    datastore_id = var.host_b_datastore
    file_id      = proxmox_virtual_environment_download_file.talos_host_b.id
    interface    = "scsi0"
    size         = 30
  }

  network_device { bridge = "vmbr0" }
  agent { enabled = true }

  initialization {
    datastore_id = var.host_b_datastore
    ip_config { ipv4 { address = "192.168.0.62/24", gateway = "192.168.0.1" } }
    dns { servers = ["192.168.0.64", "192.168.0.1"] }
  }
}

# worker-3 (grafana + prometheus): same shape as worker_2, on proxmox.host_b,
# vm_id = 621, memory = 9216, disk size = 40, ip = 192.168.0.63/24
```

### 6.5 Talos machine config, bootstrap, kubeconfig

📄 **`terraform/talos.tf`**
```hcl
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.cluster_vip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.cluster_vip}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

resource "talos_machine_configuration_apply" "cp_1" {
  depends_on                    = [proxmox_virtual_environment_vm.cp_1]
  client_configuration          = talos_machine_secrets.this.client_configuration
  machine_configuration_input   = data.talos_machine_configuration.controlplane.machine_configuration
  node                           = "192.168.0.60"
  config_patches = [
    yamlencode({ machine = { network = { hostname = "cp-1" }, install = { disk = "/dev/sda" } } })
  ]
}

resource "talos_machine_configuration_apply" "worker_1" {
  depends_on                    = [proxmox_virtual_environment_vm.worker_1]
  client_configuration          = talos_machine_secrets.this.client_configuration
  machine_configuration_input   = data.talos_machine_configuration.worker.machine_configuration
  node                           = "192.168.0.61"
  config_patches = [
    yamlencode({ machine = { network = { hostname = "worker-1" }, install = { disk = "/dev/sda" } } })
  ]
}

# worker_2 / worker_3: same pattern, node = .62 / .63, hostname worker-2 / worker-3

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.cp_1]
  node                 = "192.168.0.60"
  endpoint             = "192.168.0.60"
  client_configuration = talos_machine_secrets.this.client_configuration
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = ["192.168.0.60"]
}

data "talos_cluster_health" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = data.talos_client_configuration.this.client_configuration
  control_plane_nodes  = ["192.168.0.60"]
  worker_nodes         = ["192.168.0.61", "192.168.0.62", "192.168.0.63"]
  endpoints            = ["192.168.0.60"]
  timeouts             = { read = "10m" }
}

data "talos_cluster_kubeconfig" "this" {
  depends_on           = [data.talos_cluster_health.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = "192.168.0.60"
  endpoint             = "192.168.0.60"
}
```

📄 **`terraform/outputs.tf`**
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

### 6.6 Fill in variables and apply

📄 **`terraform/terraform.tfvars`**
```hcl
host_a_endpoint  = "https://<32gb-host-ip>:8006"
host_a_api_token = "terraform@pve!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
host_b_endpoint  = "https://<16gb-host-ip>:8006"
host_b_api_token = "terraform@pve!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

▶️ **Run, inside `terraform/`:**
```bash
terraform init
terraform plan
terraform apply
export KUBECONFIG=$(pwd)/generated/kubeconfig
export TALOSCONFIG=$(pwd)/generated/talosconfig
```

✅ **Checkpoint:** `kubectl get nodes` shows 4 nodes `Ready`. `talosctl health` passes.

---

## Part 7 — Kubernetes bootstrap layer · ~30–60 min

**Files you'll create:** `k8s/metallb-pool.yaml`

No Terraform here — this is `kubectl`/`helm` directly against the live cluster.

### 7.1 Label nodes for workload affinity
▶️ **Run:**
```bash
kubectl label node worker-1 workload=nextcloud
kubectl label node worker-2 workload=git
kubectl label node worker-3 workload=monitoring
```

### 7.2 Storage — local-path as default StorageClass
▶️ **Run:**
```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 7.3 Namespaces
▶️ **Run:**
```bash
kubectl create ns git
kubectl create ns nextcloud
kubectl create ns monitoring
```

### 7.4 MetalLB
▶️ **Run:**
```bash
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb -n metallb-system --create-namespace
```

📄 **`k8s/metallb-pool.yaml`**
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: main, namespace: metallb-system }
spec: { addresses: ["192.168.0.70-192.168.0.79"] }
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: main, namespace: metallb-system }
spec: { ipAddressPools: ["main"] }
```

▶️ **Run:**
```bash
kubectl apply -f k8s/metallb-pool.yaml
```

✅ **Checkpoint:** `kubectl get pods -n metallb-system` all `Running`. `kubectl get storageclass` shows `local-path (default)`.

---

## Part 8 — App deployment: Forgejo, Nextcloud, monitoring · ~1.5–2.5 hrs

**Files you'll create:** `ansible/inventory.yml` (final version, `localhost` group added), `helm-values/forgejo-values.yaml`, `helm-values/nextcloud-values.yaml`, `helm-values/kube-prometheus-stack-values.yaml`, `ansible/playbooks/deploy-apps.yml`

Ansible here doesn't touch the OS (Talos has no SSH) — it's just orchestrating `helm` calls via `kubernetes.core.helm` against the kubeconfig.

### 8.1 Inventory

📄 **`ansible/inventory.yml`** — this is the full file, combining every group added across earlier parts:
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
    jellyfin:
      hosts:
        jellyfin:
          ansible_host: 192.168.0.66
    pihole:
      hosts:
        pihole:
          ansible_host: 192.168.0.64
```

### 8.2 Helm values

📄 **`helm-values/nextcloud-values.yaml`**
```yaml
nodeSelector:
  workload: nextcloud
persistence:
  enabled: true
  storageClass: local-path
  size: 60Gi
service:
  type: LoadBalancer
```

📄 **`helm-values/forgejo-values.yaml`**
```yaml
nodeSelector:
  workload: git
persistence:
  enabled: true
  storageClass: local-path
  size: 20Gi
service:
  type: LoadBalancer
```

📄 **`helm-values/kube-prometheus-stack-values.yaml`**
```yaml
nodeSelector:
  workload: monitoring
prometheus:
  prometheusSpec:
    retention: 15d   # conservative — worker-3 is the node with the least headroom
```

### 8.3 Playbook

📄 **`ansible/playbooks/deploy-apps.yml`**
```yaml
- hosts: localhost
  collections: [kubernetes.core]
  vars:
    kubeconfig: "{{ playbook_dir }}/../../terraform/generated/kubeconfig"
  tasks:
    - name: Forgejo
      kubernetes.core.helm:
        name: forgejo
        chart_ref: forgejo-helm/forgejo   # confirm the exact repo-add URL in Forgejo's own docs — they host their own chart repo, not Helm Hub
        release_namespace: git
        values_files: ["{{ playbook_dir }}/../../helm-values/forgejo-values.yaml"]
        kubeconfig: "{{ kubeconfig }}"

    - name: Nextcloud
      kubernetes.core.helm:
        name: nextcloud
        chart_ref: nextcloud/nextcloud   # repo: https://nextcloud.github.io/helm/
        release_namespace: nextcloud
        values_files: ["{{ playbook_dir }}/../../helm-values/nextcloud-values.yaml"]
        kubeconfig: "{{ kubeconfig }}"

    - name: kube-prometheus-stack
      kubernetes.core.helm:
        name: monitoring
        chart_ref: prometheus-community/kube-prometheus-stack   # repo: https://prometheus-community.github.io/helm-charts
        release_namespace: monitoring
        values_files: ["{{ playbook_dir }}/../../helm-values/kube-prometheus-stack-values.yaml"]
        kubeconfig: "{{ kubeconfig }}"
```

▶️ **Run:**
```bash
ansible-playbook ansible/playbooks/deploy-apps.yml
```

✅ **Checkpoint:** `kubectl get svc -A | grep LoadBalancer` shows external IPs in the `.70–.79` range for all three; each web UI loads.

---

## Part 9 — Wire it together and protect it

No new files — configuration and verification only.

- [ ] Point DNS/hosts entries — and optionally your router's DHCP DNS setting — at Pi-hole (`.64`) and the app LoadBalancer IPs.
- [ ] Proxmox `vzdump` schedule for all 8 VMs/containers (`ollama`, `truenas`, `jellyfin`, `pihole`, `cp-1`, `worker-1`, `worker-2`, `worker-3`) → external target, all three hosts.
- [ ] `talosctl etcd snapshot` on a cron, stored off-box.
- [ ] **Dell note:** `vzdump` on `truenas` backs up its boot/config disk, not the ZFS pool itself. Rely on RAIDZ1 for drive-failure redundancy and schedule periodic scrubs in TrueNAS instead.
- [ ] Test a restore once. An untested backup is a hope, not a plan.
- [ ] Tear down and rebuild **only the cluster project**: `cd terraform && terraform destroy && terraform apply`. Pi-hole and the Dell, in their own states, stay untouched — the real test that your cluster IaC is complete on its own.

---

## Later: GPU passthrough for `ollama` (deliberately deferred)

Add once everything above is stable. When ready: uncomment the `hostpci` block in `terraform-dell/ollama.tf`, fill in the real PCI ID from `lspci | grep -i nvidia`, blacklist the host's `nvidia`/`nouveau` driver and bind the card to `vfio-pci`, then extend `configure-ollama.yml`'s compose file with `nvidia-container-toolkit` and a `deploy.resources.reservations.devices` GPU block.

Also still deferred: 3rd physical host for true control-plane HA, Longhorn/Ceph, ingress + cert-manager/TLS, GitOps.
