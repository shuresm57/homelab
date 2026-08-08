resource "proxmox_download_file" "truenas_iso" {
  content_type = "iso"
  datastore_id = var.dell_datastore
  node_name    = var.dell_node_name
  url          = "https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.5/TrueNAS-SCALE-25.10.5.iso"
}

resource "proxmox_virtual_environment_vm" "truenas" {
  name      = "truenas"
  node_name = var.dell_node_name
  vm_id     = 700
  bios      = "ovmf"
  machine   = "q35"

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 16384
  }

  efi_disk {
    datastore_id = var.dell_datastore
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = var.dell_datastore
    interface    = "sc"
  }

  cdrom {
    file_id = proxmox_download_file.truenas_iso.id
  }

  boot_order = ["ide2", "scsi0"]

  hostpci {
    device = "hostpci0"
    id     = "0000:b3:00" # replace with your controller's ID from lspci
    pcie   = true
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = var.dell_datastore
    ip_config {
      ipv4 {
        address = "192.168.0.65/24"
        gateway = "192.168.0.1"
      }
    }
    dns {
      servers = ["192.168.0.64", "192.168.0.1"]
    }
  }
}