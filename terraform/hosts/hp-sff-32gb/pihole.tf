resource "proxmox_virtual_environment_container" "pihole" {
  node_name    = var.node_name
  vm_id        = 640
  unprivileged = true
  started      = true

  operating_system {
  template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  type             = "ubuntu"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = var.datastore
    size         = 4
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "pihole"

    ip_config {
      ipv4 {
        address = "192.168.0.64/24"
        gateway = "192.168.0.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }
}