module "worker_2" {
  source = "../../modules/proxmox-vm"

  name          = "worker-2"
  vm_id         = 620
  node_name     = var.node_name
  datastore     = var.datastore
  cores         = 2
  memory_mb     = 3072
  disk_size_gb  = 30
  disk_image_id = proxmox_download_file.talos.id
  scsi_hardware = "virtio-scsi-single"
  agent_enabled = true
  ipv4_address  = "192.168.0.62/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]
}

module "worker_3" {
  source = "../../modules/proxmox-vm"

  name          = "worker-3"
  vm_id         = 621
  node_name     = var.node_name
  datastore     = var.datastore
  cores         = 2
  memory_mb     = 9216
  disk_size_gb  = 40
  disk_image_id = proxmox_download_file.talos.id
  scsi_hardware = "virtio-scsi-single"
  agent_enabled = true
  ipv4_address  = "192.168.0.63/24"
  dns_servers   = ["192.168.0.64", "192.168.0.1"]
}
