output "vms" {
  description = "VMs on this node, keyed by name. Consume with: terraform output -json vms"
  value = {
    ollama = {
      vm_id = module.ollama.vm_id
      name  = module.ollama.name
      ipv4  = module.ollama.ipv4
    }
    truenas = {
      vm_id = module.truenas.vm_id
      name  = module.truenas.name
      ipv4  = module.truenas.ipv4
    }
  }
}
