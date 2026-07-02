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

variable "pay_allowed_cidr" {
  type        = string
  description = "Trusted CIDR allowed to reach the Opale Pay internal API port."

  validation {
    condition     = trimspace(var.pay_allowed_cidr) != "" && can(cidrhost(var.pay_allowed_cidr, 0))
    error_message = "pay_allowed_cidr must be a non-empty valid CIDR (example: 198.51.100.20/32)."
  }
}
