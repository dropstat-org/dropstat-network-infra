output "public_ip" {
  description = "Elastic IP del servidor Headscale — URL que usan los clientes"
  value       = aws_eip.headscale.public_ip
}

output "server_url" {
  description = "URL completa del servidor Headscale"
  value       = "https://${local.fqdn}"
}

output "instance_id" {
  description = "ID de la instancia EC2"
  value       = module.ec2.id
}

output "oidc_secret_name" {
  description = "Nombre del secret para las credenciales OIDC de Google"
  value       = aws_secretsmanager_secret.oidc.name
}

output "oidc_secret_arn" {
  description = "ARN del secret OIDC"
  value       = aws_secretsmanager_secret.oidc.arn
}
