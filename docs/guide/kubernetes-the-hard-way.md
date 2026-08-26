# Kubernetes the hard way — on hp32

A companion to [Kelsey Hightower's tutorial](https://github.com/kelseyhightower/kubernetes-the-hard-way),
not a replacement. Upstream owns the interesting parts — certificates, etcd, wiring the control
plane together by hand. This doc owns the part upstream assumes you've already solved: getting four
machines to exist, on Proxmox, with the right addresses and names.

**Why bother, when [the main guide](proxmox-talos-k8s-build-guide.md) already gives you a working
cluster?** Because Talos hides *all* of this. It hands you a `Ready` node and never shows you the
certificate that made it trusted, the kubeconfig that let it register, or the route that lets its
pods reach another node's. Building one by hand once means that when the real cluster breaks, you
recognise which of those things broke. Do it *after* Part 6 of the main guide, so you have
something working to compare against.

## Shape

Four VMs on **hp32**, in `terraform/labs/kthw/` — its own Terraform root module and its own state,
deliberately. `terraform destroy` in that directory wipes the lab and cannot touch Pi-hole or the
Talos nodes sharing the machine.

| Name | IP | vm_id | vCPU | RAM | Disk | Role |
|---|---|---|---|---|---|---|
| `kthw-jumpbox` | `.90` | 690 | 1 | 1GB | 20GB | Admin box — you run every tutorial command from here |
| `kthw-server` | `.91` | 691 | 2 | 2GB | 20GB | etcd + API server + scheduler + controller-manager |
| `kthw-node-0` | `.92` | 692 | 2 | 2GB | 20GB | Worker, pods `10.200.0.0/24` |
| `kthw-node-1` | `.93` | 693 | 2 | 2GB | 20GB | Worker, pods `10.200.1.0/24` |

7GB total. hp32 budget: Pi-hole 1 + `cp-1` 2 + `worker-1` 10 + lab 7 = 20GB of 32GB.

The jumpbox exists because upstream's instructions assume it — every `scp`/`ssh` in the tutorial
runs from there, and the machine that holds the CA private key wanting to be separate from the
cluster is a real pattern, not a workaround. Destroy the lab when you're done and rebuild it later;
that's what the separate state is for.

## Terraform

Same `proxmox-vm` module as everything else. Ubuntu 24.04 rather than upstream's Debian 12 — the
`amd64` binaries the tutorial downloads work identically, and it matches the rest of this homelab.

📄 **`terraform/labs/kthw/versions.tf`**, **`providers.tf`**, **`variables.tf`** — copy verbatim
from `terraform/hosts/hp-sff-32gb/`, then point the tfvars at hp32:

📄 **`terraform/labs/kthw/terraform.tfvars`**
```hcl
endpoint       = "https://192.168.0.129:8006"
api_token      = "terraform@pve!terraform=<uuid>"
node_name      = "hp32"
datastore      = "local-lvm"
ssh_public_key = "ssh-ed25519 AAAA...your-actual-key"
```

📄 **`terraform/labs/kthw/main.tf`**
```hcl
resource "proxmox_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = "local"          # files go on local, never local-lvm
  node_name    = var.node_name
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

locals {
  machines = {
    jumpbox = { vm_id = 690, ip = "192.168.0.90", cores = 1, memory = 1024 }
    server  = { vm_id = 691, ip = "192.168.0.91", cores = 2, memory = 2048 }
    node-0  = { vm_id = 692, ip = "192.168.0.92", cores = 2, memory = 2048 }
    node-1  = { vm_id = 693, ip = "192.168.0.93", cores = 2, memory = 2048 }
  }
}

module "kthw" {
  source   = "../../modules/proxmox-vm"
  for_each = local.machines

  name          = "kthw-${each.key}"
  vm_id         = each.value.vm_id
  node_name     = var.node_name
  datastore     = var.datastore
  cores         = each.value.cores
  memory_mb     = each.value.memory
  disk_size_gb  = 20
  disk_image_id = proxmox_download_file.ubuntu_cloud_image.id
  ipv4_address  = "${each.value.ip}/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]

  user_account = {
    username = "ubuntu"
    password = var.console_password
    keys     = [var.ssh_public_key]
  }
}
```

A `for_each` over a map, rather than four near-identical module blocks — the machines differ only
in four values, so that's all the config should express.

▶️ **Run, inside `terraform/labs/kthw/`:**
```bash
terraform init
terraform apply
```

## Before you open the tutorial

Three pieces of setup upstream expects that Terraform doesn't do for you.

### 1. Root SSH, which the tutorial requires

Upstream's commands `ssh root@server` and copy files as root. Cloud-init gives you `ubuntu` with
sudo instead. On **each of the three cluster machines** (not the jumpbox):

```bash
ssh ubuntu@192.168.0.91 'sudo mkdir -p /root/.ssh && sudo cp ~/.ssh/authorized_keys /root/.ssh/ && \
  sudo sed -i "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config && \
  sudo systemctl restart ssh'
```

`prohibit-password` keeps key-only auth. This is fine for a throwaway lab on a LAN and would not be
fine anywhere else.

### 2. `machines.txt`

The tutorial drives everything from this file on the jumpbox. Columns are IP, FQDN, hostname, and
pod subnet:

📄 **`~/kubernetes-the-hard-way/machines.txt`** (on `kthw-jumpbox`)
```
192.168.0.91 server.kubernetes.local server
192.168.0.92 node-0.kubernetes.local node-0 10.200.0.0/24
192.168.0.93 node-1.kubernetes.local node-1 10.200.1.0/24
```

Note `kubernetes.local` — that's upstream's convention and it lives purely in `/etc/hosts` on
these four machines. It is unrelated to `home.arpa`, which is Pi-hole's and is how *you* reach the
VMs from your laptop. Two namespaces, deliberately not mixed.

### 3. Jumpbox setup

```bash
ssh ubuntu@192.168.0.90
sudo apt update && sudo apt install -y wget curl vim openssl git
git clone --depth 1 https://github.com/kelseyhightower/kubernetes-the-hard-way.git
cd kubernetes-the-hard-way
```

Then follow the tutorial's own prerequisites lab to download the binaries. It fetches `amd64`
builds by default, which is what these VMs are.

## Then follow upstream

Work through the labs in order. They cover, roughly: provisioning the CA and generating every
certificate, generating kubeconfigs, the data encryption key, bootstrapping etcd, bootstrapping the
control plane, bootstrapping the workers, remote `kubectl` access, pod network routes, and a smoke
test.

Two places where this environment differs from what upstream assumes:

**Pod network routes.** Upstream has you add static routes so node-0's pods can reach node-1's.
All four VMs are on the same `vmbr0` bridge and the same `/24`, so this Just Works with plain
routes — no tunnelling, no CNI overlay:

```bash
# on server
ip route add 10.200.0.0/24 via 192.168.0.92
ip route add 10.200.1.0/24 via 192.168.0.93
# on node-0
ip route add 10.200.1.0/24 via 192.168.0.93
# on node-1
ip route add 10.200.0.0/24 via 192.168.0.92
```

These do not survive a reboot. That's fine for a lab; making them persistent is a netplan file if
you care.

**Cluster CIDRs.** `10.200.0.0/16` for pods and `10.32.0.0/24` for services, per upstream. Both are
deliberately disjoint from the Talos cluster's `10.244.0.0/16` and `10.96.0.0/12` — the two
clusters run simultaneously on the same bridge, and overlapping CIDRs would produce
routing failures that look like random pod-to-pod timeouts.

✅ **Done when:** the smoke-test lab passes — you can deploy nginx, exec into it, port-forward to
it, read its logs, and hit it through a NodePort service.

## What Talos was doing for you

The point of the exercise. Everything below is a thing you did by hand here, and a thing Talos does
silently in the main guide's Part 5:

| By hand here | Talos |
|---|---|
| Generate a CA, then a cert per component with correct SANs | `talos_machine_secrets` generates the whole PKI |
| Write a kubeconfig per component | Embedded in the machine config |
| systemd units for etcd, apiserver, scheduler, controller-manager | Static pods, supervised by the `machined` init |
| Install and configure containerd, runc, CNI plugins, kubelet | Baked into the immutable image |
| Static routes between pod subnets | The CNI handles it |
| Upgrades: replace binaries, restart units, hope | `talosctl upgrade` — atomic A/B image swap with rollback |
| SSH in and edit files to fix things | No SSH, no shell. The API is the only interface. |

That last row is the real trade. Talos removes the ability to log in and fix something by hand —
which is exactly what makes it reproducible, and exactly what makes it feel claustrophobic the
first time something breaks. Having done it the hard way once, you'll know what you'd have been
reaching for.

## Cleanup

```bash
cd terraform/labs/kthw && terraform destroy
```

Separate state is what makes that safe. Then delete the four `kthw-*` records from Pi-hole.
