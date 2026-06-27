# Output pour récupérer l'IP facilement
output "instance_ip" {
  value       = openstack_compute_instance_v2.opale_core.access_ip_v4
  description = "L'IP publique de ton instance Opale Core"
}