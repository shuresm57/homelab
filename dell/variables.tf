variable "dell_endpoint" {
  type = string
}

variable "dell_root_password" {
  type      = string
  sensitive = true
}

variable "dell_node_name" {
  type    = string
  default = "dell"
}

variable "dell_datastore" {
  type    = string
  default = "local-lvm"
}

variable "ssh_public_key" {
  type = string
}
