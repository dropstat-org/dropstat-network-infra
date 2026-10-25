output "role_arn" {
  description = "ARN del rol que va en el workflow de build."
  value       = aws_iam_role.this.arn
}

output "oidc_provider_arn" {
  description = "ARN del provider OIDC creado en la cuenta."
  value       = module.github_oidc_provider.arn
}
