terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}

provider "proxmox" {
  alias     = "hp16"
  endpoint  = var.pve_hosts.hp16.endpoint
  api_token = var.pve_hosts.hp16.api_token
  insecure  = true
  ssh {
    agent    = true
    username = "root"
  }
}

provider "proxmox" {
  alias     = "hp32"
  endpoint  = var.pve_hosts.hp32.endpoint
  api_token = var.pve_hosts.hp32.api_token
  insecure  = true
  ssh {
    agent    = true
    username = "root"
  }
}

provider "proxmox" {
  alias     = "dell"
  endpoint  = var.pve_hosts.dell.endpoint
  api_token = var.pve_hosts.dell.api_token
  insecure  = true
  ssh {
    agent    = true
    username = "root"
  }
}

