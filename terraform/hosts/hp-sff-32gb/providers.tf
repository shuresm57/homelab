provider "proxmox" {
  endpoint  = var.endpoint
  insecure  = true
  api_token = var.api_token
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}