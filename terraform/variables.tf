variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "ssh_allowed_ips" {
  description = "CIDRs allowed to SSH. Empty = allow all (not recommended)."
  type        = list(string)
  default     = []
}

variable "allow_public_http" {
  description = "Allow inbound 80/443 on the Hetzner firewall. Keep false when using Cloudflare Tunnel."
  type        = bool
  default     = false
}

variable "ssh_port" {
  type    = number
  default = 22
}

variable "server_name" {
  type    = string
  default = "sentry"
}

variable "server_image" {
  description = "Hetzner image slug for the server OS."
  type        = string
  default     = "ubuntu-24.04"
}

variable "server_type" {
  description = "Recommended for this repo: ccx23 (4 dedicated vCPU, 16GB RAM, 160GB disk)."
  type        = string
  default     = "ccx23"
}

variable "server_location" {
  type    = string
  default = "nbg1"

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1", "ash", "hil", "sin"], var.server_location)
    error_message = "Must be a valid Hetzner location."
  }
}

variable "environment" {
  type    = string
  default = "production"

  validation {
    condition     = contains(["production", "staging"], var.environment)
    error_message = "Must be 'production' or 'staging'."
  }
}

variable "enable_volume" {
  description = "Attach a separate data volume (adds ~EUR 2-5/mo)."
  type        = bool
  default     = false
}

variable "volume_size_gb" {
  type    = number
  default = 50
}

variable "cloudflare_api_token" {
  description = "Needs Zone:DNS:Edit, Zone:Zone Settings:Edit, and Cloudflare Tunnel edit permissions."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID. Optional when it can be inferred from the zone."
  type        = string
  default     = ""
}

variable "cloudflare_zone_name" {
  type = string
}

variable "cloudflare_record_name" {
  type    = string
  default = "sentry"
}

variable "domain" {
  description = "e.g. sentry.example.com"
  type        = string
}

variable "sentry_admin_email" {
  type = string
}

# Cloudflare R2 Configuration
variable "enable_r2" {
  description = "Enable Cloudflare R2 for Sentry filestore"
  type        = bool
  default     = true
}

variable "r2_bucket_name" {
  description = "R2 bucket name for Sentry filestore"
  type        = string
  default     = "sentry-filestore"
}

variable "r2_bucket_location" {
  description = "R2 location hint. weur keeps the bucket close to a UK/EU deployment."
  type        = string
  default     = "WEUR"

  validation {
    condition     = contains(["APAC", "EEUR", "ENAM", "WEUR", "WNAM", "OC"], var.r2_bucket_location)
    error_message = "r2_bucket_location must be one of: APAC, EEUR, ENAM, WEUR, WNAM, OC."
  }
}

variable "r2_account_id" {
  description = "Cloudflare account ID for R2. Leave empty to reuse cloudflare_account_id."
  type        = string
  default     = ""
  sensitive   = true
}

variable "r2_access_key_id" {
  description = "Existing R2 S3 access key ID. Leave empty to keep Sentry on filesystem storage."
  type        = string
  default     = ""
  sensitive   = true
}

variable "r2_secret_access_key" {
  description = "Existing R2 S3 secret access key. Leave empty to keep Sentry on filesystem storage."
  type        = string
  default     = ""
  sensitive   = true
}
