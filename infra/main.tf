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

# Configuration du Provider (Infomaniak utilise OpenStack)
provider "openstack" {
  # Les identifiants seront injectés via tes variables d'environnement OpenRC
}

# 1. Récupération de l'image Ubuntu 24.04
data "openstack_images_image_v2" "alpine" {
  name        = "Alpine Linux 3" # Vérifie le nom exact dans ton manager si besoin
  most_recent = true
}

# 2. Définition de la clé SSH pour l'accès bare-metal
resource "openstack_compute_keypair_v2" "opale_key" {
  name       = "opale-core-key"
  public_key = var.ssh_public_key
}

# 3. Création de l'instance avec activation du vTPM
resource "openstack_compute_instance_v2" "opale_vault" {
  name            = "opale-vault-prod"
  image_id        = data.openstack_images_image_v2.ubuntu.id
  flavor_name     = "a1-ram2-disk20-perf1" # 1 vCPU / 2 Go RAM
  key_pair        = openstack_compute_keypair_v2.opale_key.name
  security_groups = ["default"]

  # Injection dynamique des arguments spécifiques à cette instance
  user_data = <<-EOF
    #!/bin/sh
    # Téléchargement ou exécution du script générique
    sh ${path.module}/scripts/harden-alpine-generic.sh \
      --ssh-port 22 \
      --app-port 8200 \
      --app-dir /opt/opale-vault
  EOF

  # C'est ici qu'on force OpenStack à émuler la puce TPM 2.0 pour le Vault
  metadata = {
    "hw_tpm_version" = "2.0"
    "hw_tpm_model"   = "tpm-tis"
  }

  network {
    name = "Ext-Net" # Le nom du réseau public chez Infomaniak pour avoir une IP
  }
}
