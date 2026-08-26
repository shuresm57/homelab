# Network inventory

The single source of truth for addresses and names. Everything else — guides, playbooks,
Terraform — should refer to a **name** from this file and let this file own the number.

Subnet `192.168.0.0/24`, gateway `192.168.0.1`, internal domain **`home.arpa`**
([RFC 8375](https://www.rfc-editor.org/rfc/rfc8375.html) — reserved for home networks, so it
can never collide with a real TLD the way `.local`/`.lan` can).

> **TODO — confirm the router's DHCP range.** Everything below is statically assigned. If the
> router's pool overlaps `.60–.99` or `.125/.129/.254`, you will eventually get a duplicate-address
> outage that looks like a random service dying. Shrink the DHCP pool to something like
> `.150–.250` before building anything else out.

## Reserved ranges

| Range | Use |
|---|---|
| `.1` | Gateway / router |
| `.60–.67` | Static infrastructure guests (Talos nodes, Pi-hole, TrueNAS, Ollama, Jellyfin) |
| `.70–.79` | MetalLB pool — Kubernetes `LoadBalancer` services |
| `.90–.93` | Kubernetes-the-hard-way lab (throwaway) |
| `.125`, `.129`, `.254` | Proxmox hosts themselves |
| `.150–.250` | Suggested DHCP pool (confirm on the router) |

## Naming

This repo currently spells the same machine four ways: `hp-sff-32gb` (directories, CI),
`hp_sff_32GB.md` (docs), `pve-a` (Proxmox node name), "HP Mini SFF 1" (README). Pick one.

**Decision: `dell`, `hp32`, `hp16`** for both the Proxmox node name and the DNS name.

- `dell` is already correct and live — nothing to do.
- `pve-a` only exists as a default in a root module that has **never been applied**, so it is free
  to change. Edit `terraform/hosts/hp-sff-32gb/variables.tf` and the tfvars.
- The 16GB host has no Terraform at all yet, so it is also free.
- Renaming a Proxmox node that already has guests is disruptive — do it on an empty node:
  edit `/etc/hosts`, `hostnamectl set-hostname hp32`, `pvecm updatecerts -f`, reboot.

Directory names stay `hp-sff-32gb` / `hp-sff-16gb` (descriptive, and CI paths depend on them);
only the *node* and *DNS* names normalise.

## Proxmox hosts

| DNS name | IP | Node name | Hardware | Runs | Terraform root module |
|---|---|---|---|---|---|
| `dell.home.arpa` | `192.168.0.254` | `dell` | Dell 5820, Xeon W-2245, 96GB, RTX 4000 | Ollama, TrueNAS, (Jellyfin) | `terraform/hosts/dell/` |
| `hp32.home.arpa` | `192.168.0.129` | `pve-a` → **rename to `hp32`** | HP SFF, i7, 32GB | Pi-hole, `cp-1`, `worker-1`, KTHW lab | `terraform/hosts/hp-sff-32gb/` |
| `hp16.home.arpa` | `192.168.0.125` | *(unset)* → **`hp16`** | HP SFF, i7, 16GB | `worker-2`, `worker-3` | `terraform/hosts/hp-sff-16gb/` *(to be created)* |

Web UI is `https://<ip>:8006` on all three.

## Guests

Status legend: **live** = running now · **planned** = not built yet · **blocked** = waiting on something.

| DNS name | IP | ID | Host | Runs | Ports | Source | Status |
|---|---|---|---|---|---|---|---|
| `cp-1.home.arpa` | `.60` | 610 | hp32 | Talos control plane | 6443, 50000 | `hosts/hp-sff-32gb/` | planned |
| `worker-1.home.arpa` | `.61` | 611 | hp32 | Talos worker — Nextcloud | 50000 | `hosts/hp-sff-32gb/` | planned |
| `worker-2.home.arpa` | `.62` | 620 | hp16 | Talos worker — Forgejo | 50000 | `hosts/hp-sff-16gb/` | planned |
| `worker-3.home.arpa` | `.63` | 621 | hp16 | Talos worker — monitoring | 50000 | `hosts/hp-sff-16gb/` | planned |
| `pihole.home.arpa` | `.64` | 640 | hp32 | Pi-hole (LXC, Ubuntu 24.04) | 53, 80 | `hosts/hp-sff-32gb/pihole.tf` | planned |
| `truenas.home.arpa` | `.65` | 700 | dell | TrueNAS SCALE 25.10.5 + HBA passthrough | 80, 443, 2049 | `hosts/dell/vms.tf` | **live** (pool blocked on 3rd drive) |
| `jellyfin.home.arpa` | `.66` | 701 | dell | Jellyfin + media stack | 8096, 8080, 9696, 8989, 7878, 8191 | *(not written)* | blocked on TrueNAS pool |
| `ollama.home.arpa` | `.67` | 702 | dell | Ollama + open-webui | 11434 (API), 3000 (UI) | `hosts/dell/vms.tf` | VM **live**, service not installed |

`cp-1` doubles as the cluster endpoint: `https://192.168.0.60:6443`. Single control plane for now,
so `k8s.home.arpa` is an alias for `.60` rather than a real VIP — worth keeping as a separate name
so that adding real HA later is a DNS change, not a change to every kubeconfig.

## MetalLB — Kubernetes LoadBalancer services

Pool is `.70–.79`. **Pin these** with `spec.loadBalancerIP` (or the
`metallb.universe.tf/loadBalancerIPs` annotation) rather than letting MetalLB allocate — otherwise
this table goes stale the first time a service is redeployed in a different order.

| DNS name | IP | Service |
|---|---|---|
| `nextcloud.home.arpa` | `.70` | Nextcloud |
| `git.home.arpa` | `.71` | Forgejo (HTTP + SSH) |
| `grafana.home.arpa` | `.72` | Grafana |
| `prometheus.home.arpa` | `.73` | Prometheus |
| *(free)* | `.74–.79` | Room for ingress, cert-manager, future services |

## Kubernetes-the-hard-way lab

Throwaway, on hp32, own Terraform state (`terraform/labs/kthw/`) so it can be destroyed without
touching anything else. See [kubernetes-the-hard-way.md](guide/kubernetes-the-hard-way.md).

| DNS name | IP | ID | RAM | Role |
|---|---|---|---|---|
| `kthw-jumpbox.home.arpa` | `.90` | 690 | 1GB | Admin box — where you run the tutorial from |
| `kthw-server.home.arpa` | `.91` | 691 | 2GB | etcd + control plane |
| `kthw-node-0.home.arpa` | `.92` | 692 | 2GB | Worker |
| `kthw-node-1.home.arpa` | `.93` | 693 | 2GB | Worker |

## Cluster-internal CIDRs

These never appear on the LAN, but they must not overlap each other or `192.168.0.0/24`.

| Cluster | Pods | Services |
|---|---|---|
| Talos (`homelab`) | `10.244.0.0/16` | `10.96.0.0/12` |
| KTHW lab | `10.200.0.0/16` (`/24` per node: node-0 `10.200.0.0/24`, node-1 `10.200.1.0/24`) | `10.32.0.0/24` |

Deliberately disjoint, so the two clusters can run at the same time on the same bridge.

## Pi-hole local DNS records

None of the names above resolve until these exist. Pi-hole web UI → **Settings → Local DNS →
DNS Records**, or write them straight into `/etc/pihole/custom.list` on the container
(`<ip> <name>`, one per line) and `pihole restartdns`.

```
192.168.0.254   dell.home.arpa
192.168.0.129   hp32.home.arpa
192.168.0.125   hp16.home.arpa
192.168.0.60    cp-1.home.arpa
192.168.0.60    k8s.home.arpa
192.168.0.61    worker-1.home.arpa
192.168.0.62    worker-2.home.arpa
192.168.0.63    worker-3.home.arpa
192.168.0.64    pihole.home.arpa
192.168.0.65    truenas.home.arpa
192.168.0.66    jellyfin.home.arpa
192.168.0.67    ollama.home.arpa
192.168.0.70    nextcloud.home.arpa
192.168.0.71    git.home.arpa
192.168.0.72    grafana.home.arpa
192.168.0.73    prometheus.home.arpa
192.168.0.90    kthw-jumpbox.home.arpa
192.168.0.91    kthw-server.home.arpa
192.168.0.92    kthw-node-0.home.arpa
192.168.0.93    kthw-node-1.home.arpa
```

Two things make these actually reachable from your laptop:

1. Every guest already gets `dns { servers = ["192.168.0.64", "192.168.0.1"] }` from Terraform, so
   guests resolve `home.arpa` as soon as Pi-hole is up.
2. Your workstation and phones do **not** — they use whatever the router hands out. Set the
   router's DHCP DNS server to `192.168.0.64` once Pi-hole is verified working. Until then, add
   entries to `/etc/hosts` by hand or you will chase phantom DNS failures.

**Note the module default disagrees with intent:** `terraform/modules/proxmox-vm/variables.tf:88`
defaults `dns_servers` to `["192.168.0.1", "192.168.0.64"]` — router first, so Pi-hole gets
bypassed. Every call site overrides it in the right order, but the default should be flipped so a
new VM that forgets to pass it still filters.

## RAM budgets

| Host | Total | Allocated | Breakdown |
|---|---|---|---|
| dell | 96GB | 80GB (90GB once Jellyfin lands) | ollama 64 + truenas 16 (+ jellyfin 10) |
| hp32 | 32GB | 13GB (20GB with the KTHW lab up) | pihole 1 + cp-1 2 + worker-1 10 (+ lab 7) |
| hp16 | 16GB | 12GB | worker-2 3 + worker-3 9 |

hp16 is the tight one — 12GB of 16GB allocated leaves ~4GB for Proxmox itself. That is workable
but it is the first thing to reduce if the host starts swapping; trim `worker-3` (Prometheus
retention) before anything else.
