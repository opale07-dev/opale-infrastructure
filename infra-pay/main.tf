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
    key    = "prod/opale-pay/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  bootstrap_ssh_port = 22
  ssh_port           = 2222
  pay_internal_port  = 8080
  service_name       = "opale-pay"
  environment        = "prod"
}

provider "openstack" {
}

data "openstack_images_image_v2" "alpine" {
  name        = "Alpine Linux 3"
  most_recent = true
}

resource "openstack_compute_keypair_v2" "opale_key" {
  name       = "${local.service_name}-key"
  public_key = var.ssh_public_key
}

resource "openstack_compute_instance_v2" "opale_pay" {
  name            = "${local.service_name}-${local.environment}"
  image_id        = data.openstack_images_image_v2.alpine.id
  flavor_name     = "a2-ram4-disk50-perf1"
  key_pair        = openstack_compute_keypair_v2.opale_key.name
  security_groups = [openstack_compute_secgroup_v2.secgroup_opale.name]

  network {
    name = "ext-net1"
  }
}

resource "openstack_compute_secgroup_v2" "secgroup_opale" {
  name        = "${local.service_name}-secgroup"
  description = "Security group for Opale Pay (restricted SSH and Pay API)"

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

  rule {
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    ip_protocol = "tcp"
    cidr        = var.admin_cidr
  }

  rule {
    from_port   = local.pay_internal_port
    to_port     = local.pay_internal_port
    ip_protocol = "tcp"
    cidr        = var.pay_allowed_cidr
  }
}
