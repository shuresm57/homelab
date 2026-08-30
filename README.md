# Personal Homelab

This repo reflects the state of my own personal homelab.

## The homelab consists of three machines:

1. Dell 5820 Workstation: Xeon 2245, 96GB RAM and a 8GB RTX 4000. Called `dell`.

2. HP Mini SFF 1: Intel i7, 32GB RAM. Called `hp32`.

3. HP Mini SFF 2: Intel i7, 16GB RAM. Called `hp16`.

All three run Proxmox. The guests on top of them run NixOS, except TrueNAS.

# Architecture and Stack

The stack is deliberately small. Three layers, and each one owns exactly one thing:

| Layer | Tool | Owns |
|---|---|---|
| Hardware to VMs | Proxmox, declared in Terraform | That the machines exist, with disks and IPs |
| VM to running services | NixOS | Packages, services, users, firewall, backups |
| A few services | Docker, declared by NixOS | The things that only ship as containers |

Docker is the container runtime and nothing more, and only where upstream ships nothing else.
I don't write compose files. Containers are declared in NixOS as `virtualisation.oci-containers`,
so they roll back with the rest of the system and there is no second place I have to remember to
look. Nothing on `dns` or `git` uses it — both are native NixOS services. The first real use will
be open-webui in stage 2.

Kubernetes is not here yet. I do want to learn it, but I would rather have a lab that actually
works first, so it is deferred. `.60`, `.62` and `.63` are held for it.

There is one Terraform root for the whole lab (`terraform/infra/`), with a provider alias per
Proxmox host. It used to be one root per machine, which meant the same boilerplate four times.

# Addresses

Subnet is `192.168.0.0/24`, gateway is `192.168.0.1`, internal domain is `home.arpa`.

## Proxmox hosts

| Name | IP | Hardware | Runs |
|---|---|---|---|
| `dell` | `192.168.0.254` | Dell 5820, Xeon W-2245, 96GB, RTX 4000 | `truenas`, `ollama` |
| `hp32` | `192.168.0.129` | HP SFF, i7, 32GB | nothing yet |
| `hp16` | `192.168.0.125` | HP SFF, i7, 16GB | `dns`, `git` |

Web UI is `https://<ip>:8006` on all three.

## Guests

| Name | IP | ID | Host | What it runs | Status |
|---|---|---|---|---|---|
| *(reserved)* | `.60` | — | — | future Kubernetes | — |
| `git` | `.61` | 641 | hp16 | Forgejo + nginx | **running** |
| *(reserved)* | `.62` | — | — | future Kubernetes | — |
| *(reserved)* | `.63` | — | — | future Kubernetes | — |
| `dns` | `.64` | 640 | hp16 | Pi-hole (native NixOS service) | **running** |
| `truenas` | `.65` | 700 | dell | TrueNAS SCALE + HBA passthrough | running, pool blocked on a 3rd drive |
| `jellyfin` | `.66` | — | dell | Jellyfin | planned |
| `ollama` | `.67` | 702 | dell | Ollama + open-webui | VM running, service not installed |
| `monitoring` | `.68` | — | hp32 | Grafana + Prometheus | planned |
| `backup` | `.69` | — | hp32 | restic target + NFS | planned |

The full detail, including the reserved ranges and the cluster CIDRs, lives in
[network-inventory.md](/docs/network-inventory.md).

## Documentation

The documentation for each machine will be split into three parts:

1. Explanation

A brief explanation of what I need the machine for, and how it serves me a purpose. It was quite important for me from the start, that I did not just build services upon services, just for the sake of it. I need to have a usecase for each one, something that actually makes my life easier, or improves upon it.

2. Setup

How I will get from bare metal to a running service.

3. Deadline.

Although I don't have any real deadlines, it's important for me to keep a consistent focus and more so because in real work life, there is always a deadline.

---

[Dell documentation](/docs/dell.md)

[HP SFF 32GB documentation](/docs/hp_sff_32GB.md)

[HP SFF 16GB documentation](/docs/hp_sff_16GB.md)

[Build guide](/docs/homelab-plan.md) — stage 1 is built; stages 2 and 3 are still ahead

[Network inventory](/docs/network-inventory.md) — owns every address

[What already shipped](/docs/guide/completed.md) — read the "Known drift" section before touching the Dell
