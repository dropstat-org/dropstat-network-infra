variable "name" {
  description = "Nombre base para todos los recursos (e.g. 'dropstat')"
  type        = string
}

variable "instance_type" {
  description = "Tipo de instancia EC2. t3.nano suficiente para <20 usuarios concurrentes."
  type        = string
  default     = "t3.nano"
}

variable "advertise_routes" {
  description = "CIDRs a anunciar via Tailscale. 10.0.0.0/8 cubre todas las cuentas via TGW."
  type        = string
  default     = "10.0.0.0/8"
}

variable "tags" {
  description = "Tags a aplicar a todos los recursos"
  type        = map(string)
  default     = {}
}
