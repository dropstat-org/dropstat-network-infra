output "asg_name" {
  description = "Nombre del Auto Scaling Group"
  value       = module.asg.autoscaling_group_name
}

output "secret_arn" {
  description = "ARN del secret — cargar auth key aquí después del apply"
  value       = aws_secretsmanager_secret.authkey.arn
}

output "secret_name" {
  description = "Nombre del secret para el auth key"
  value       = aws_secretsmanager_secret.authkey.name
}

output "launch_template_id" {
  description = "ID del launch template"
  value       = aws_launch_template.tailscale.id
}
