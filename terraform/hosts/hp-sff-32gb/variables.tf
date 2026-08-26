variable "endpoint" {
  type = string
}

variable "api_token" {
  type      = string
  sensitive = true
}

variable "node_name" {
  type    = string
  default = "pve-a"
}

variable "datastore" {
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