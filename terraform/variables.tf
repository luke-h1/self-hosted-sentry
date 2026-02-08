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

variable "ssh_port" {
  type    = number
  default = 22
}

variable "server_name" {
  type    = string
  default = "sentry"
}

variable "server_type" {
  description = "CX53 (~EUR 28.49/mo): 16 vCPU, 32GB RAM, 240GB disk"
  type        = string
  default     = "cx53"
}

variable "server_location" {
  type    = string
  default = "nbg1"

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1", "ash", "hil"], var.server_location)
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
  description = "Needs Zone:DNS:Edit + Zone:Zone Settings:Edit"
  type        = string
  sensitive   = true
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
