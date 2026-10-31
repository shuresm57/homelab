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
| `.60`, `.62`, `.63` | Held for Kubernetes, whenever it happens |
| `.61`, `.64–.69` | Static infrastructure guests, all NixOS |
| `.70–.79` | MetalLB pool — deferred along with the rest of Kubernetes |
| `.90–.93` | Kubernetes-the-hard-way lab — deferred |
| `.125`, `.129`, `.254` | Proxmox hosts themselves |
| `.150–.250` | Suggested DHCP pool (confirm on the router) |

## Naming

**`dell`, `hp32`, `hp16`** for the Proxmox node name and the DNS name alike. This is settled —
all three hosts now report those hostnames, so the old `pve-a` default and the four different
spellings of the same machine are gone.

Directory names no longer vary either: there is one Terraform root, `terraform/infra/`, with a
provider alias per host.

## Proxmox hosts

| DNS name | IP | Node name | Hardware | Runs | Terraform root module |
|---|---|---|---|---|---|
| `dell.home.arpa` | `192.168.0.254` | `dell` | Dell 5820, Xeon W-2245, 96GB, RTX 4000 | `ollama`, `media` | `terraform/infra/` |
| `hp32.home.arpa` | `192.168.0.129` | `hp32` | HP SFF, i7, 32GB | *(empty, **powered off** to save power — WoL it when monitoring/backup get built)* | `terraform/infra/` |
| `hp16.home.arpa` | `192.168.0.125` | `hp16` | HP SFF, i7, 16GB | `dns`, `git` | `terraform/infra/` |

Web UI is `https://<ip>:8006` on all three.

## Guests

Status legend: **live** = running now · **planned** = not built yet · **blocked** = waiting on something.

| DNS name | IP | ID | Host | Runs | Ports | Source | Status |
|---|---|---|---|---|---|---|---|
| `home.home.arpa` | `.65` | 704 | dell | Homepage dashboard (nginx on 80) | 80 | `terraform/infra/` | **live** |
| `git.home.arpa` | `.61` | 641 | hp16 | Forgejo + Keycloak (`auth.vstov.dk`) + nginx | 80, 443, 2222 | `terraform/infra/` | **live** |
| `dns.home.arpa` | `.64` | 640 | hp16 | Pi-hole (`services.pihole-ftl`) | 53, 80 | `terraform/infra/` | **live** |
| `media.home.arpa` | `.66` | 703 | dell | Nixarr: jellyfin, sonarr, radarr, prowlarr, bazarr, seerr, qbittorrent (Mullvad-confined) + ZFS RAIDZ1 `tank` over the HBA | 8096, 8989, 7878, 9696, 6767, 5055, 5252 | `terraform/infra/` | **live** |
| `ollama.home.arpa` | `.67` | 702 | dell | Ollama + open-webui | 11434 (API), 3000 (UI) | `terraform/infra/` | VM **live**, NixOS build in progress |
| `monitoring.home.arpa` | `.68` | — | hp32 | Grafana + Prometheus | 80 | *(not written)* | planned |
| `backup.home.arpa` | `.69` | — | hp32 | restic target + NFS | 2049 | *(not written)* | planned |

`.60`, `.62` and `.63` are deliberately unused. They were `cp-1`, `worker-2` and `worker-3` on the
Talos cluster, which has been destroyed; holding them means adding Kubernetes later is a new entry
here rather than a renumbering.

## MetalLB — Kubernetes LoadBalancer services

**Deferred.** Nothing below exists — it is here so the addresses stay reserved.

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

**Deferred.** Never built.

Throwaway, on hp32, own Terraform state (`terraform/labs/kthw/`) so it can be destroyed without
touching anything else. The walkthrough that lived here was removed with the rest of the
Kubernetes material; upstream is
[kelseyhightower/kubernetes-the-hard-way](https://github.com/kelseyhightower/kubernetes-the-hard-way).

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
192.168.0.61    git.home.arpa
192.168.0.64    dns.home.arpa
192.168.0.66    jellyfin.home.arpa
192.168.0.66    media.home.arpa
192.168.0.67    ollama.home.arpa
192.168.0.68    grafana.home.arpa
```

These are no longer maintained by hand. They live in `nix/data/network.nix`, which
`homelab.services.pihole.records` defaults to, and are generated into Pi-hole's
`FTLCONF_dns_hosts` at build time. This block is a copy for reading, not the source. Edit the
Nix file.

Two things make these actually reachable from your laptop:

1. Every guest already gets `dns { servers = ["192.168.0.64", "192.168.0.1"] }` from Terraform, so
   guests resolve `home.arpa` as soon as Pi-hole is up.
2. Your workstation and phones do **not** — they use whatever the router hands out. Set the
   router's DHCP DNS server to `192.168.0.64` once Pi-hole is verified working. Until then, add
   entries to `/etc/hosts` by hand or you will chase phantom DNS failures.

The module default now agrees with intent: `terraform/modules/proxmox-vm/variables.tf` defaults
`dns_servers` to `["192.168.0.64", "192.168.0.1"]` — Pi-hole first, so a VM that forgets to pass
it still filters.

## VPN confinement

`qbittorrent` on `media` runs inside the `wg` network namespace (Mullvad `se-mma-wg-102`,
Malmö). Nothing else on the host is tunneled — verified: the namespace exits at a Mullvad
address while the host keeps its own ISP route.

The wg-quick file lives at **`/data/.secret/vpn/wg.conf` on `media` only** (`0400 root:root`).
`homelab.services.media.vpn.wgConf` is set to that path as a **string**, not a Nix path — a path
literal would copy the private key into the world-readable `/nix/store` on every machine that
evaluates the flake. The repo copy under `nix/.secret/` is gitignored and must stay that way.

Killswitch verified: with `wg0` down the namespace has no route off-box (the only default route
is `dev wg0`), so the client cannot fall back to the bare WAN address.

## RAM budgets

| Host | Total | Allocated | Breakdown |
|---|---|---|---|
| dell | 96GB | 76GB | ollama 64 + media 10 + home 2 |
| hp32 | 32GB | 0GB (12GB once monitoring and backup land) | nothing yet (+ monitoring 8 + backup 4) |
| hp16 | 16GB | 6GB | dns 2 + git 4 |

There is a lot of headroom now that the Talos cluster is gone — hp16 sits at 6GB of 16GB and hp32
is empty. That spare capacity is where Kubernetes goes when I get to it.
