locals {
  vms = {
    hp16 = {
      dns = {
        vm_id        = 640
        cores        = 1
        memory_mb    = 2048
        disk_size_gb = 16
        ip           = "192.168.0.64/24"
      }
      git = {
        vm_id        = 641
        cores        = 2
        memory_mb    = 4096
        disk_size_gb = 40
        ip           = "192.168.0.61/24"
      }
    }

    dell = {} # TODO 
    hp32 = {} # TODO
  }
}

module "hp16" {
  source   = "../modules/proxmox-vm"
  for_each = local.vms.hp16

  providers = { proxmox = proxmox.hp16 }

  name          = each.key
  vm_id         = each.value.vm_id
  node_name     = var.pve_hosts.hp16.node_name
  datastore     = var.pve_hosts.hp16.datastore
  cores         = each.value.cores
  memory_mb     = each.value.memory_mb
  disk_size_gb  = each.value.disk_size_gb
  disk_image_id = var.nixos_image_file_id
  ipv4_address  = each.value.ip
  dns_servers   = ["192.168.0.64", "192.168.0.1"]

  user_account = {
    username = "nixos"
    password = var.console_password
    keys     = [var.ssh_public_key]
  }
}
