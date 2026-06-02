variable "name" {
  description = "Nombre base para todos los recursos (e.g. 'dropstat')"
  type        = string
}

variable "instance_type" {
  description = "Tipo de instancia. t3.small recomendado para <50 usuarios."
  type        = string
  default     = "t3.small"
}

variable "tags" {
  type    = map(string)
  default = {}
}
