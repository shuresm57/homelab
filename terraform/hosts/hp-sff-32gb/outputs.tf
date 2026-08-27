output "vms" {
  description = "VMs on this node, keyed by name. Consume with: terraform output -json vms"
  value = {
    cp-1     = { vm_id = module.cp_1.vm_id, name = module.cp_1.name, ipv4 = module.cp_1.ipv4 }
    worker-1 = { vm_id = module.worker_1.vm_id, name = module.worker_1.name, ipv4 = module.worker_1.ipv4 }
  }
}
