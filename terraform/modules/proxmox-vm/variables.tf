variable "name" {
  type     = string
  nullable = false

  validation {
    condition     = length(var.name) > 0
    error_message = "name must not be empty."
  }
}

variable "vm_id" {
  type     = number
  nullable = false

  validation {
    condition     = var.vm_id > 0
    error_message = "vm_id must be a positive number."
  }
}

variable "node_name" {
  type     = string
  nullable = false

  validation {
    condition     = length(var.node_name) > 0
    error_message = "node_name must not be empty."
  }
}

variable "datastore" {
  type     = string
  nullable = false

  validation {
    condition     = length(var.datastore) > 0
    error_message = "datastore must not be empty."
  }
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "disk_size_gb" {
  type     = number
  nullable = false

  validation {
    condition     = var.disk_size_gb > 0
    error_message = "disk_size_gb must be a positive number and initialized"
  }
}

variable "disk_image_id" {
  type    = string
  default = null
}

variable "iso_file_id" {
  type    = string
  default = null
}

variable "ipv4_address" {
  type     = string
  nullable = false

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", var.ipv4_address))
    error_message = "ipv4_address must be a valid IPv4 CIDR, e.g. 192.168.0.10/24."
  }
}

variable "ipv4_gateway" {
  type    = string
  default = "192.168.0.1"
}

variable "dns_servers" {
  type    = list(string)
  default = ["192.168.0.1", "192.168.0.64"]
}

variable "hostpci_ids" {
  type    = list(any)
  default = []
}

variable "boot_order" {
  type    = list(string)
  default = null
}

variable "user_account" {
  type = object({
    username = string
    password = string
    keys     = list(string)
  })
  default   = null
  sensitive = true
}
