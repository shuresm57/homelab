resource "proxmox_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.dell_node_name
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_vm" "ollama" {
  name      = "ollama"
  node_name = var.dell_node_name
  vm_id     = 702
  bios      = "ovmf"
  machine   = "q35"

  cpu {
    cores = 6
    type  = "host"
  }

  memory {
    dedicated = 65536
  }

  efi_disk {
    datastore_id = var.dell_datastore
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = var.dell_datastore
    file_id      = proxmox_download_file.ubuntu_cloud_image.id
    interface    = "scsi0"
    size         = 80
  }

  network_device {
    bridge = "vmbr0"
  }

  agent {
    enabled = false
  }

  initialization {
    datastore_id = var.dell_datastore
    ip_config {
      ipv4 {
        address = "192.168.0.67/24"
        gateway = "192.168.0.1"
      }
    }

    dns {
      servers = ["192.168.0.64", "192.168.0.1"]
    }

    user_account {
      username = "ubuntu"
      password = var.ollama_console_password # add this as a new sensitive variable
      keys     = [var.ssh_public_key]
    }
  }
}