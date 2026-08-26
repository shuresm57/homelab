provider "proxmox" {
  endpoint  = var.dell_endpoint
  insecure  = true
  api_token = var.dell_api_token
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}
