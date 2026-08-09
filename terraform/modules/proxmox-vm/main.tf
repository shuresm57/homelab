resource "proxmox_virtual_environment_vm" "this" {
  name       = var.name
  node_name  = var.node_name
  vm_id      = var.vm_id
  bios       = "ovmf"
  machine    = "q35"
  boot_order = var.boot_order

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  efi_disk {
    datastore_id = var.datastore
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = var.datastore
    file_id      = var.disk_image_id
    interface    = "scsi0"
    size         = var.disk_size_gb
  }

  dynamic "cdrom" {
    for_each = var.iso_file_id == null ? [] : [var.iso_file_id]
    content {
      file_id   = cdrom.value
      interface = "ide2"
    }
  }

  dynamic "hostpci" {
    for_each = var.hostpci_ids
    content {
      device = "hostpci${hostpci.key}"
      id     = hostpci.value
      pcie   = true
    }
  }

  network_device {
    bridge = "vmbr0"
  }

  agent {
    enabled = false
  }

  initialization {
    datastore_id = var.datastore

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.ipv4_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    dynamic "user_account" {
      for_each = var.user_account == null ? [] : [var.user_account]
      content {
        username = user_account.value.username
        password = user_account.value.password
        keys     = user_account.value.keys
      }
    }
  }
}
