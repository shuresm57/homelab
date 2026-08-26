resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

resource "proxmox_download_file" "talos" {
  content_type            = "iso"
  datastore_id            = "local"          # not local-lvm — this is a file
  node_name               = var.node_name
  file_name               = "talos-${var.talos_version}-homelab.img"
  url                     = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/nocloud-amd64.raw.gz"
  decompression_algorithm = "gz"
  overwrite               = false
}
