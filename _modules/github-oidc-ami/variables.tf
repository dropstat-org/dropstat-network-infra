variable "role_name" {
  description = <<-EOT
    Nombre del rol IAM que asume GitHub Actions. Tiene que empezar con
    `dropstat-`: la policy de TerraformCI acota sus permisos de IAM a
    arn:aws:iam::*:role/dropstat-*, asi que cualquier otro nombre da
    AccessDenied en el apply.
  EOT
  type        = string
  default     = "dropstat-gha-headscale-ami"

  validation {
    condition     = startswith(var.role_name, "dropstat-")
    error_message = "role_name debe empezar con `dropstat-` para caer dentro del alcance de TerraformCI."
  }
}

variable "github_org" {
  description = "Organizacion de GitHub."
  type        = string
  default     = "dropstat-org"
}

variable "github_repository" {
  description = "Repo autorizado a asumir el rol."
  type        = string
}

variable "trusted_workflow_refs" {
  description = <<-EOT
    Archivos de workflow exactos autorizados (claim job_workflow_ref). Es
    StringEquals: un workflow nuevo en el mismo repo no hereda el acceso.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.trusted_workflow_refs) > 0
    error_message = "Debe haber al menos un workflow autorizado: sin esta condicion el trust queda abierto a cualquier workflow del repo."
  }
}

variable "ssm_parameter_paths" {
  description = "Parametros de SSM donde el workflow puede publicar el id de la AMI."
  type        = list(string)
  default     = ["/dropstat/headscale/ami-id"]
}

variable "tags" {
  description = "Tags adicionales."
  type        = map(string)
  default     = {}
}
