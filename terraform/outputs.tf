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
