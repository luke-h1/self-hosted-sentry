terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Uncomment for remote state:
  backend "s3" {
    bucket                      = "sentry-terraform-state-lho"
    key                         = "sentry/terraform.tfstate"
    region                      = "eu-west-2"
    encrypt                     = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "hcloud_ssh_key" "sentry" {
  name       = "${var.server_name}-deploy-key"
  public_key = file(var.ssh_public_key_path)
}

locals {
  ssh_allowed_ips = length(var.ssh_allowed_ips) > 0 ? var.ssh_allowed_ips : ["0.0.0.0/0", "::/0"]
}

resource "hcloud_firewall" "sentry" {
  name = "${var.server_name}-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = local.ssh_allowed_ips
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "sentry" {
  name         = var.server_name
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = var.server_location
  ssh_keys     = [hcloud_ssh_key.sentry.id]
  firewall_ids = [hcloud_firewall.sentry.id]

  labels = {
    service     = "sentry"
    environment = var.environment
    managed_by  = "terraform"
  }

  user_data = templatefile("${path.module}/cloud-init.yml", {
    domain             = var.domain
    sentry_admin_email = var.sentry_admin_email
    ssh_port           = var.ssh_port
  })

  lifecycle {
    prevent_destroy = false # flip to true after first deploy
  }
}

resource "hcloud_volume" "sentry_data" {
  count     = var.enable_volume ? 1 : 0
  name      = "${var.server_name}-data"
  size      = var.volume_size_gb
  server_id = hcloud_server.sentry.id
  automount = true
  format    = "ext4"

  labels = {
    service     = "sentry"
    environment = var.environment
    managed_by  = "terraform"
  }

  lifecycle {
    prevent_destroy = false # flip to true after first deploy
  }
}

data "cloudflare_zone" "domain" {
  name = var.cloudflare_zone_name
}

resource "cloudflare_record" "sentry" {
  zone_id = data.cloudflare_zone.domain.id
  name    = var.cloudflare_record_name
  content = hcloud_server.sentry.ipv4_address
  type    = "A"
  ttl     = 1
  proxied = true
}

resource "cloudflare_record" "sentry_ipv6" {
  zone_id = data.cloudflare_zone.domain.id
  name    = var.cloudflare_record_name
  content = hcloud_server.sentry.ipv6_address
  type    = "AAAA"
  ttl     = 1
  proxied = true
}

