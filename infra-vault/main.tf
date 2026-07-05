terraform {
  required_version = ">= 1.5.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
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
  admin_user          = "ubuntu"
  app_dir             = "/opt/opale-vault"
}

# Configuration du Provider (Infomaniak utilise OpenStack)
provider "openstack" {
  # Les identifiants seront injectés via tes variables d'environnement OpenRC
}

# 1. Image privée Ubuntu LTS avec vTPM (doctrine DevOps : Ubuntu LTS minimal).
# Les propriétés hw_tpm_* doivent être portées par l'IMAGE (impossible sur
# l'image publique Infomaniak) — les poser en metadata d'instance ne fait rien.
# tpm-crb est le modèle recommandé pour TPM 2.0. vTPM exige la région dc4-a.
# Si l'import web_download échoue chez Glance, retirer `web_download` pour
# laisser le provider télécharger puis uploader l'image.
resource "openstack_images_image_v2" "ubuntu_tpm" {
  name             = "opale-ubuntu-26.04-tpm"
  image_source_url = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
  container_format = "bare"
  disk_format      = "qcow2"
  visibility       = "private"
  web_download     = true

  properties = {
    hw_tpm_version = "2.0"
    hw_tpm_model   = "tpm-crb"
  }
}

# Bundle du module de maintenance (scripts + unités systemd) pour cloud-init.
data "archive_file" "maintenance" {
  type        = "zip"
  source_dir  = "${path.module}/../maintenance"
  output_path = "${path.module}/.maintenance.zip"
}

# 2. Définition de la clé SSH pour l'accès bare-metal
resource "openstack_compute_keypair_v2" "opale_key" {
  name       = "${local.service_name}-key"
  public_key = var.ssh_public_key
}

# 3. Création de l'instance avec activation du vTPM
resource "openstack_compute_instance_v2" "opale_vault" {
  name            = "${local.service_name}-${local.environment}"
  image_id        = openstack_images_image_v2.ubuntu_tpm.id
  flavor_name     = "a1-ram2-disk20-perf1" # 1 vCPU / 2 Go RAM
  key_pair        = openstack_compute_keypair_v2.opale_key.name
  security_groups = [openstack_compute_secgroup_v2.secgroup_opale.name]
  config_drive    = true
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_user          = local.admin_user
    app_dir             = local.app_dir
    ssh_port            = local.ssh_port
    vault_internal_port = local.vault_internal_port
    service_name        = local.service_name
    backup_volume       = "${local.service_name}_vault-data"
    harden_script_b64   = filebase64("${path.module}/../scripts/harden-ubuntu-vps.sh")
    maintenance_zip_b64 = filebase64(data.archive_file.maintenance.output_path)
  })

  lifecycle {
    # image_id est ignoré pour qu'une nouvelle image "most_recent" ne déclenche
    # jamais un remplacement implicite de la VM (ex: apply de la fenêtre SSH).
    # Migration d'image = décision explicite via terraform apply -replace.
    ignore_changes = [user_data, image_id]
  }

  # NB: ne PAS mettre hw_tpm_* ici — en metadata d'instance, Nova les ignore.
  # Le vTPM vient des propriétés de l'image privée ubuntu_tpm ci-dessus.

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
