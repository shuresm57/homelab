# Personal Homelab

Three machines, all on Proxmox: `dell` (96GB, RTX 4000), `hp32` (32GB), `hp16` (16GB). Everything on top of them is provisioned with Terraform and configured with NixOS.

## Why Nix

I chose NixOS for one reason: reproducibility. The whole system, packages, services, users, firewall rules, is described in config instead of built up by hand over time. If a machine dies or I mess something up badly enough, I rebuild it straight from the repository instead of trying to remember what I clicked six months ago.

Paired with Terraform, this actually feels like a bit of a superpower. Terraform provisions the VM, NixOS declares everything that runs on it, and together the whole homelab goes from bare metal to running services with one `apply` and one rebuild. No manual setup steps hiding anywhere.

## What's running

- `git`, on `hp16`: Forgejo, my own git server
- `dns`, on `hp16`: Pi-hole for local DNS and ad blocking
- `ollama`, on `dell`: local LLM inference using the RTX 4000

A media server, monitoring and backups are next, and Kubernetes is on the roadmap once the rest of the stack is settled.
