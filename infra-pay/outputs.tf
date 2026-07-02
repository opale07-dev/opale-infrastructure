output "instance_ip" {
  value       = openstack_compute_instance_v2.opale_pay.access_ip_v4
  description = "The public IP of the Opale Pay instance."
}

output "instance_name" {
  value       = openstack_compute_instance_v2.opale_pay.name
  description = "The provisioned instance name."
}

output "ssh_port" {
  value       = 2222
  description = "The hardened SSH admin port."
}

output "ssh_user" {
  value       = "ubuntu"
  description = "The SSH admin user for the Opale Pay instance."
}
