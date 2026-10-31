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
        memory_mb    = 6144
        disk_size_gb = 40
        ip           = "192.168.0.61/24"

        usb_devices = [
          { host = "2-3", usb3 = true }, # LaCie Rugged Mini -> /mnt/backup1
          { host = "2-7", usb3 = true }, # Samsung Flash FIT -> /mnt/backup2
        ]
      }
    }

    dell = {
      ollama = {
        vm_id        = 702
        cores        = 6
        memory_mb    = 65536
        disk_size_gb = 80
        ip           = "192.168.0.67/24"

        hostpci_mappings = ["ollama-gpu"]
      }
      home = {
        vm_id        = 704
        cores        = 2
        memory_mb    = 2048
        disk_size_gb = 16
        ip           = "192.168.0.65/24"
      }
      media = {
        vm_id        = 703
        cores        = 4
        memory_mb    = 10240
        disk_size_gb = 80 # nixarr state + Jellyfin metadata/transcodes, off tank
        ip           = "192.168.0.66/24"

        # The HBA the retired truenas guest used to hold. The mapping is bound
        # to the card, not the VM, so the name stays as it is.
        hostpci_mappings = ["truenas-it"]
      }
    }

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

  # Only some VMs have these, so the key is absent from the rest.
  usb_devices      = try(each.value.usb_devices, [])
  hostpci_mappings = try(each.value.hostpci_mappings, [])

  user_account = {
    username = "nixos"
    password = var.console_password
    keys     = [var.ssh_public_key]
  }
}

module "dell" {
  source   = "../modules/proxmox-vm"
  for_each = local.vms.dell

  providers = { proxmox = proxmox.dell }

  name          = each.key
  vm_id         = each.value.vm_id
  node_name     = var.pve_hosts.dell.node_name
  datastore     = var.pve_hosts.dell.datastore
  cores         = each.value.cores
  memory_mb     = each.value.memory_mb
  disk_size_gb  = each.value.disk_size_gb
  disk_image_id = var.nixos_image_file_id
  ipv4_address  = each.value.ip
  dns_servers   = ["192.168.0.64", "192.168.0.1"]

  # Only some VMs have these, so the key is absent from the rest.
  usb_devices      = try(each.value.usb_devices, [])
  hostpci_mappings = try(each.value.hostpci_mappings, [])

  user_account = {
    username = "nixos"
    password = var.console_password
    keys     = [var.ssh_public_key]
  }
}
