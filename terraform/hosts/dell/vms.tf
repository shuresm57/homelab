module "ollama" {
  source = "../../modules/proxmox-vm"

  name          = "ollama"
  vm_id         = 702
  node_name     = var.dell_node_name
  datastore     = var.dell_datastore
  cores         = 6
  memory_mb     = 65536
  disk_size_gb  = 80
  disk_image_id = proxmox_download_file.ubuntu_cloud_image.id
  ipv4_address  = "192.168.0.67/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]

  user_account = {
    username = "ubuntu"
    password = var.ollama_console_password
    keys     = [var.ssh_public_key]
  }
}

module "truenas" {
  source = "../../modules/proxmox-vm"

  name             = "truenas"
  vm_id            = 700
  node_name        = var.dell_node_name
  datastore        = var.dell_datastore
  cores            = 4
  memory_mb        = 16384
  disk_size_gb     = 32
  iso_file_id      = proxmox_download_file.truenas_iso.id
  boot_order       = ["ide2", "scsi0"]
  hostpci_mappings = ["truenas-it"]
  ipv4_address     = "192.168.0.65/24"
  dns_servers      = ["192.168.0.64", "192.168.0.1"]
}

