provier "proxmox" {
  endpoint = var.dell_endpoint
  insecure = true
  username = "root@pam"
  password = var.dell_root_password
}
