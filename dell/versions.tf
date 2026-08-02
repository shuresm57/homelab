terraform {
  required_version = ">= 1.7.0"
  required_provides {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}
