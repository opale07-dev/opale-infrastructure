terraform {
  required_version = ">= 1.5.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53.0"
    }
  }

  backend "s3" {
    bucket = "opale-core-tfstate"
    key    = "prod/opale-data/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  ssh_port           = 2222
  data_internal_port = 3001
  service_name       = "opale-data"
  environment        = "prod"
  admin_user         = "ubuntu"
  app_dir            = "/opt/opale-data"
}

provider "openstack" {
}

data "openstack_images_image_v2" "ubuntu" {
  name_regex  = "^Ubuntu 26\\.04.*LTS.*"
  most_recent = true
}

resource "openstack_compute_keypair_v2" "opale_key" {
  name       = "${local.service_name}-key"
  public_key = var.ssh_public_key
}

resource "openstack_compute_instance_v2" "opale_data" {
  name            = "${local.service_name}-${local.environment}"
  image_id        = data.openstack_images_image_v2.ubuntu.id
  flavor_name     = "a1-ram2-disk20-perf1"
  key_pair        = openstack_compute_keypair_v2.opale_key.name
  security_groups = [openstack_compute_secgroup_v2.secgroup_opale.name]
  config_drive    = true
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_user         = local.admin_user
    app_dir            = local.app_dir
    ssh_port           = local.ssh_port
    data_internal_port = local.data_internal_port
    harden_script_b64  = filebase64("${path.module}/../scripts/harden-ubuntu-vps.sh")
  })

  lifecycle {
    ignore_changes = [user_data]
  }

  network {
    name = "ext-net1"
  }
}

resource "openstack_compute_secgroup_v2" "secgroup_opale" {
  name        = "${local.service_name}-secgroup"
  description = "Security group for Opale Data Index (restricted SSH and Data Index API)"

  rule {
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    ip_protocol = "tcp"
    cidr        = var.admin_cidr
  }

  rule {
    from_port   = local.data_internal_port
    to_port     = local.data_internal_port
    ip_protocol = "tcp"
    cidr        = var.data_allowed_cidr
  }
}
