locals {
  # Talos >= 1.13 generates a HostnameConfig document with `auto: stable`, which
  # conflicts with setting machine.network.hostname in v1alpha1. Drop that
  # document so the static hostnames below are the only hostname source.
  drop_hostname_config = <<-EOT
    apiVersion: v1alpha1
    kind: HostnameConfig
    $patch: delete
  EOT
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

resource "talos_machine_configuration_apply" "cp_1" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.control_plane
  config_patches = [
    local.drop_hostname_config,
    yamlencode({
      machine = {
        network = { hostname = "cp-1" }
        install = { disk = "/dev/sda" }
      }
    })
  ]
}

resource "talos_machine_configuration_apply" "workers" {
  for_each = var.workers

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value
  config_patches = [
    local.drop_hostname_config,
    yamlencode({
      machine = {
        network = { hostname = each.key }
        install = { disk = "/dev/sda" }
      }
    })
  ]
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.cp_1]
  node                 = var.control_plane
  endpoint             = var.control_plane
  client_configuration = talos_machine_secrets.this.client_configuration
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = concat([var.control_plane], values(var.workers))
  endpoints            = [var.control_plane]
}

data "talos_cluster_health" "this" {
  depends_on           = [talos_machine_bootstrap.this, talos_machine_configuration_apply.workers]
  client_configuration = data.talos_client_configuration.this.client_configuration
  control_plane_nodes  = [var.control_plane]
  worker_nodes         = values(var.workers)
  endpoints            = [var.control_plane]
  timeouts             = { read = "10m" }
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [data.talos_cluster_health.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_plane
  endpoint             = var.control_plane
}
