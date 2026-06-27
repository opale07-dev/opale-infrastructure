# Output pour récupérer l'IP facilement
output "instance_ip" {
  value       = openstack_compute_instance_v2.opale_vault.access_ip_v4
  description = "L'IP publique de ton instance Opale Vault"
}

output "private_key" {
  value     = openstack_compute_keypair_v2.opale_key.private_key
  sensitive = true
}