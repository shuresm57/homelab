module "cp_1" {
  source = "../../modules/proxmox-vm"

  name          = "cp-1"
  vm_id         = 610
  node_name     = var.node_name
  datastore     = var.datastore
  cores         = 2
  memory_mb     = 2048
  disk_size_gb  = 20
  disk_image_id = proxmox_download_file.talos.id
  scsi_hardware = "virtio-scsi-single"
  agent_enabled = true
  ipv4_address  = "192.168.0.60/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]
}

module "worker_1" {
  source = "../../modules/proxmox-vm"

  name          = "worker-1"
  vm_id         = 611
  node_name     = var.node_name
  datastore     = var.datastore
  cores         = 4
  memory_mb     = 10240
  disk_size_gb  = 80
  disk_image_id = proxmox_download_file.talos.id
  scsi_hardware = "virtio-scsi-single"
  agent_enabled = true
  ipv4_address  = "192.168.0.61/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]
}
