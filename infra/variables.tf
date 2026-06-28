variable "ssh_public_key" {
  type        = string
  description = "Public SSH key injected from CI secrets or local environment."
}

variable "admin_cidr" {
  type        = string
  description = "Trusted admin CIDR allowed to reach SSH."
}

variable "vault_allowed_cidr" {
  type        = string
  description = "Trusted CIDR allowed to reach the Vault HTTPS port."
}
