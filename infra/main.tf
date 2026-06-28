terraform {
  required_version = ">= 1.5.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53.0"
    }
  }

  # Configuration du stockage d'état souverain chez Infomaniak
  backend "s3" {
    bucket = "opale-core-tfstate"
    key    = "prod/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  bootstrap_ssh_port  = 22
  ssh_port            = 2222
  vault_internal_port = 8443
  service_name        = "opale-vault"
  environment         = "prod"
}

# Configuration du Provider (Infomaniak utilise OpenStack)
provider "openstack" {
  # Les identifiants seront injectés via tes variables d'environnement OpenRC
}

# 1. Récupération de l'image Alpine
data "openstack_images_image_v2" "alpine" {
  name        = "Alpine Linux 3" # Vérifie le nom exact dans ton manager si besoin
  most_recent = true
}

# 2. Définition de la clé SSH pour l'accès bare-metal
resource "openstack_compute_keypair_v2" "opale_key" {
  name       = "${local.service_name}-key"
  public_key = var.ssh_public_key
}

# 3. Création de l'instance avec activation du vTPM
resource "openstack_compute_instance_v2" "opale_vault" {
  name            = "${local.service_name}-${local.environment}"
  image_id        = data.openstack_images_image_v2.alpine.id
  flavor_name     = "a1-ram2-disk20-perf1" # 1 vCPU / 2 Go RAM
  key_pair        = openstack_compute_keypair_v2.opale_key.name
  security_groups = [openstack_compute_secgroup_v2.secgroup_opale.name]

  lifecycle {
    ignore_changes = [user_data]
  }

  # C'est ici qu'on force OpenStack à émuler la puce TPM 2.0 pour le Vault
  metadata = {
    "hw_tpm_version" = "2.0"
    "hw_tpm_model"   = "tpm-tis"
  }

  network {
    name = "ext-net1" # Le nom du réseau public chez Infomaniak pour avoir une IP
  }
}

# Définition du Groupe de Sécurité durci
resource "openstack_compute_secgroup_v2" "secgroup_opale" {
  name        = "${local.service_name}-secgroup"
  description = "Security group for Opale Vault (Restricted SSH and Vault)"

  dynamic "rule" {
    for_each = trimspace(var.bootstrap_cidr) == "" ? [] : [
      local.bootstrap_ssh_port,
      local.ssh_port,
    ]

    content {
      from_port   = rule.value
      to_port     = rule.value
      ip_protocol = "tcp"
      cidr        = var.bootstrap_cidr
    }
  }

  # Hardened SSH admin port restricted to a trusted CIDR.
  rule {
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    ip_protocol = "tcp"
    cidr        = var.admin_cidr
  }

  # Restrictive Vault API rule.
  rule {
    from_port   = local.vault_internal_port
    to_port     = local.vault_internal_port
    ip_protocol = "tcp"
    cidr        = var.vault_allowed_cidr
  }
}
