provider "proxmox" {
  endpoint  = var.host_a_endpoint
  insecure  = true
  api_token = vat.host_a_api_token
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}