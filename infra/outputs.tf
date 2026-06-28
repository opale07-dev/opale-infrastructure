# Output pour récupérer l'IP facilement
output "instance_ip" {
  value       = openstack_compute_instance_v2.opale_vault.access_ip_v4
  description = "L'IP publique de ton instance Opale Vault"
}

output "instance_name" {
  value       = openstack_compute_instance_v2.opale_vault.name
  description = "The provisioned instance name."
}

output "ssh_port" {
  value       = 2222
  description = "The hardened SSH admin port."
}
