resource "proxmox_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.dell_node_name
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

resource "proxmox_download_file" "truenas_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.dell_node_name
  url          = "https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.5/TrueNAS-SCALE-25.10.5.iso"
}
