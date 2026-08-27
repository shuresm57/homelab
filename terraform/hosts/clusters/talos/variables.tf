variable "cluster_name" {
  type    = string
  default = "homelab"
}

variable "talos_version" {
  type    = string
  default = "v1.13.5"
}

variable "control_plane" {
  type    = string
  default = "192.168.0.60"
}

variable "workers" {
  description = "Worker node hostname => IP"
  type        = map(string)
  default = {
    worker-1 = "192.168.0.61"
    worker-2 = "192.168.0.62"
    worker-3 = "192.168.0.63"
  }
}
