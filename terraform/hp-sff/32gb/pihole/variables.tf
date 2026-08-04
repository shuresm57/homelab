variable "host_a_endpoint" {
  type = string
}

variable "host_a_api_token" {
  type      = string
  sensitive = true
}

variable "host_a_node_name" {
  type    = string
  default = "pve-a"
}

variable "host_a_datastore" {
  type    = string
  default = "local-lvm"
}

variable "proxmox_ssh_user" {
  type    = string
  default = "root"
}

variable "ssh_public_key" {
  type = string
}