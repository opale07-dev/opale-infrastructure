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
  ssh_port           = 2222
  vault_internal_port = 8443
  service_name       = "opale-vault"
  environment        = "prod"
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
    create_before_destroy = true
  }

  # Bootstrap inline so the VM can actually execute the hardening baseline at first boot.
  user_data = <<-EOF
    #!/bin/sh
    cat >/root/harden-alpine-vps.sh <<'SCRIPT'
${file("${path.module}/../scripts/harden-alpine-vps.sh")}
SCRIPT
    cat >/root/opale-vault-sync.sh <<'SCRIPT'
${file("${path.module}/../scripts/opale-vault-sync.sh")}
SCRIPT
    chmod 700 /root/harden-alpine-vps.sh
    chmod 700 /root/opale-vault-sync.sh
    /bin/sh /root/harden-alpine-vps.sh \
      --ssh-port ${local.ssh_port} \
      --app-port ${local.vault_internal_port} \
      --app-dir /opt/opale-vault
    install -m 700 /root/opale-vault-sync.sh /usr/local/bin/opale-vault-sync
    mkdir -p /etc/local.d /etc/periodic/15min /opt/opale-vault
    cat >/etc/local.d/opale-vault-sync.start <<'SCRIPT'
#!/bin/sh
/usr/local/bin/opale-vault-sync >>/var/log/opale-vault-sync.log 2>&1 &
SCRIPT
    cat >/etc/periodic/15min/opale-vault-sync <<'SCRIPT'
#!/bin/sh
/usr/local/bin/opale-vault-sync >>/var/log/opale-vault-sync.log 2>&1
SCRIPT
    chmod 755 /etc/local.d/opale-vault-sync.start /etc/periodic/15min/opale-vault-sync
    rc-update add local default
    cat >/opt/opale-vault/deploy.env <<'SCRIPT'
# Fill this file once on the VM, then the backend deployment is pull-based and autonomous.
GITHUB_DEPLOY_USER=
GITHUB_DEPLOY_PAT=
VAULT_ADMIN_PUBKEYS=
VAULT_TPM_NV_INDEX=0x1500016
SCRIPT
    chmod 600 /opt/opale-vault/deploy.env
  EOF

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
