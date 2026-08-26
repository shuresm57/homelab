variable "dell_endpoint" {
  type = string
}

variable "dell_node_name" {
  type    = string
  default = "dell"
}

variable "dell_datastore" {
  type    = string
  default = "local"
}

variable "ssh_public_key" {
  type = string
}

variable "ollama_console_password" {
  type      = string
  sensitive = true
}

variable "dell_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_ssh_user" {
  type    = string
  default = "root"
}