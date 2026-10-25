output "zone_id" {
  description = "ID de la zona publica"
  value       = aws_route53_zone.vpn.zone_id
}

output "name_servers" {
  description = "Los 4 nameservers que hay que cargar como registro NS en GoDaddy para delegar el subdominio"
  value       = aws_route53_zone.vpn.name_servers
}

output "fqdn" {
  description = "FQDN del servidor Headscale una vez delegada la zona"
  value       = aws_route53_record.apex.fqdn
}

output "server_url" {
  description = "URL que va a reemplazar la forma nip.io en headscale-server y en dropstat-aws-sso"
  value       = "https://${var.domain_name}"
}
