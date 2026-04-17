output "server_ipv4" {
  value = hcloud_server.sentry.ipv4_address
}

output "server_ipv6" {
  value = hcloud_server.sentry.ipv6_address
}

output "server_status" {
  value = hcloud_server.sentry.status
}

output "server_type" {
  value = var.server_type
}

output "sentry_url" {
  value = "https://${var.domain}"
}

output "ssh_command" {
  value = var.ssh_port != 22 ? "ssh -p ${var.ssh_port} root@${hcloud_server.sentry.ipv4_address}" : "ssh root@${hcloud_server.sentry.ipv4_address}"
}

output "volume_enabled" {
  value = var.enable_volume
}

output "volume_id" {
  value = var.enable_volume ? hcloud_volume.sentry_data[0].id : "none"
}

output "cloudflare_record_id" {
  value = cloudflare_record.sentry.id
}

output "cloudflare_tunnel_id" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.sentry.id
  description = "Cloudflare Tunnel UUID."
}

output "cloudflare_tunnel_cname_target" {
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.sentry.id}.cfargotunnel.com"
  description = "Tunnel target for the proxied CNAME."
}

output "r2_bucket_name" {
  value       = var.enable_r2 ? cloudflare_r2_bucket.sentry_filestore[0].name : "disabled"
  description = "Cloudflare R2 bucket for Sentry filestore"
}

output "r2_endpoint" {
  value       = var.enable_r2 ? "https://${nonsensitive(local.r2_account_id)}.r2.cloudflarestorage.com" : "disabled"
  description = "R2 S3-compatible endpoint"
}
