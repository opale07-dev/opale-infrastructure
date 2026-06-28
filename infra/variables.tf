variable "ssh_public_key" {
  type        = string
  description = "Public SSH key injected from CI secrets or local environment."
}

variable "admin_cidr" {
  type        = string
  description = "Trusted admin CIDR allowed to reach SSH."

  validation {
    condition     = trimspace(var.admin_cidr) != "" && can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a non-empty valid CIDR (example: 203.0.113.10/32)."
  }
}

variable "vault_allowed_cidr" {
  type        = string
  description = "Trusted CIDR allowed to reach the Vault HTTPS port."

  validation {
    condition     = trimspace(var.vault_allowed_cidr) != "" && can(cidrhost(var.vault_allowed_cidr, 0))
    error_message = "vault_allowed_cidr must be a non-empty valid CIDR (example: 198.51.100.20/32)."
  }
}

variable "bootstrap_cidr" {
  type        = string
  description = "Temporary CIDR allowed to reach the image's initial SSH port 22 during GitHub Actions bootstrap. Empty disables the rule."
  default     = ""

  validation {
    condition     = trimspace(var.bootstrap_cidr) == "" || can(cidrhost(var.bootstrap_cidr, 0))
    error_message = "bootstrap_cidr must be empty or a valid CIDR (example: 203.0.113.10/32)."
  }
}
