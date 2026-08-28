variable "pve_hosts" {
  description = "One entry per Proxmox host."
  type = map(object({
    endpoint  = string
    node_name = string
    datastore = string
    api_token = string
  }))
  sensitive = true
}

variable "ssh_public_key" {
  type = string
}

variable "console_password" {
  description = "Fallback password for the Proxmox web console. SSH is key-only."
  type        = string
  sensitive   = true
}

variable "nixos_image_file_id" {
  description = "Proxmox file ID of the NixOS base image built in 1.2, e.g. local:iso/nixos.qcow2"
  type        = string
}
