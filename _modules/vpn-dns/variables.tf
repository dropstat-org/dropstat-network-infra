variable "domain_name" {
  description = "FQDN de la zona publica, ej. vpn.dropstat.com"
  type        = string
}

variable "public_ip" {
  description = "Elastic IP del servidor Headscale — output public_ip de _modules/headscale-server"
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.public_ip))
    error_message = "public_ip tiene que ser una IPv4, no un hostname."
  }
}

variable "ttl" {
  description = "TTL del registro A. Bajo a proposito: si la EIP cambia, el corte dura minutos y no horas."
  type        = number
  default     = 60
}

variable "comment" {
  description = "Comentario de la zona"
  type        = string
  default     = "Public zone for the Headscale control plane - NS delegated from GoDaddy"
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
