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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
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
  public_key = file(pathexpand(var.ssh_public_key_path))
}

data "cloudflare_zone" "domain" {
  name = var.cloudflare_zone_name
}

locals {
  ssh_allowed_ips       = length(var.ssh_allowed_ips) > 0 ? var.ssh_allowed_ips : ["0.0.0.0/0", "::/0"]
  cloudflare_account_id = var.cloudflare_account_id != "" ? var.cloudflare_account_id : var.r2_account_id
  r2_account_id         = var.r2_account_id != "" ? var.r2_account_id : local.cloudflare_account_id
}

resource "hcloud_firewall" "sentry" {
  name = "${var.server_name}-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = local.ssh_allowed_ips
  }

  dynamic "rule" {
    for_each = var.allow_public_http ? ["80", "443"] : []

    content {
      direction  = "in"
      protocol   = "tcp"
      port       = rule.value
      source_ips = ["0.0.0.0/0", "::/0"]
    }
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
  image        = var.server_image
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
    domain                  = var.domain
    sentry_admin_email      = var.sentry_admin_email
    ssh_port                = var.ssh_port
    cloudflare_tunnel_token = cloudflare_zero_trust_tunnel_cloudflared.sentry.tunnel_token
    r2_bucket_name          = var.enable_r2 ? var.r2_bucket_name : ""
    r2_account_id           = local.r2_account_id
    r2_access_key_id        = var.enable_r2 ? var.r2_access_key_id : ""
    r2_secret_access_key    = var.enable_r2 ? var.r2_secret_access_key : ""
  })

  lifecycle {
    prevent_destroy = false # flip to true after first deploy
  }
}

resource "random_bytes" "tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "sentry" {
  account_id = local.cloudflare_account_id
  name       = "${var.server_name}-${var.environment}"
  config_src = "cloudflare"
  secret     = random_bytes.tunnel_secret.base64
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "sentry" {
  account_id = local.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.sentry.id

  config {
    ingress_rule {
      hostname = var.domain
      service  = "http://127.0.0.1:80"
    }

    ingress_rule {
      service = "http_status:404"
    }
  }
}

resource "cloudflare_record" "sentry" {
  zone_id = data.cloudflare_zone.domain.id
  name    = var.cloudflare_record_name
  content = "${cloudflare_zero_trust_tunnel_cloudflared.sentry.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

# Bypass Cloudflare cache for Sentry (required for CSRF cookies to work)
resource "cloudflare_ruleset" "sentry_cache_bypass" {
  zone_id     = data.cloudflare_zone.domain.id
  name        = "Sentry cache bypass"
  description = "Bypass cache for Sentry to ensure CSRF cookies work correctly"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules {
    action = "set_cache_settings"
    action_parameters {
      cache = false
    }
    expression  = "(http.host eq \"${var.domain}\")"
    description = "Bypass cache for Sentry dashboard"
    enabled     = true
  }
}

# Cloudflare R2 Bucket for Sentry filestore
resource "cloudflare_r2_bucket" "sentry_filestore" {
  count      = var.enable_r2 ? 1 : 0
  account_id = local.r2_account_id
  name       = var.r2_bucket_name
  location   = var.r2_bucket_location
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
