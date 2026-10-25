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
  description = <<-DESC
    CIDRs a anunciar via Tailscale, separados por coma. 10.0.0.0/8 cubre las
    cuentas de workload via TGW. Para prod se anuncian los /24 reales de
    dropstat-vpc y no el 172.31.0.0/16 completo: ese /16 es el CIDR de las VPC
    default de AWS y anunciarlo le rompe la red local a los clientes.
  DESC
  type        = string
  default     = "10.0.0.0/8"
}

variable "headscale_url" {
  description = "URL del servidor Headscale. e.g. https://1.2.3.4 o https://vpn.dropstat.com"
  type        = string
}

variable "tags" {
  description = "Tags a aplicar a todos los recursos"
  type        = map(string)
  default     = {}
}

# ── Override de red ───────────────────────────────────────────────────────────
# Por defecto el modulo toma VPC y subnets de tm-aws-account-data, que resuelve
# la cuenta network. Para desplegar un router en otra cuenta (management/prod)
# hay que pasar vpc_id y subnet_ids explicitos.

variable "vpc_id" {
  description = "VPC donde va el router. null = tomarla de tm-aws-account-data."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = <<-DESC
    Subnets del ASG. Vacio = las 'secures' de tm-aws-account-data.
    Deben tener salida a internet (NAT): el launch template no asigna IP publica,
    asi que una subnet con solo IGW no sirve.

    OBLIGATORIO si se pasa vpc_id: en ese caso no se consulta
    tm-aws-account-data y no hay de donde sacarlas.
  DESC
  type        = list(string)
  default     = []
}

variable "forward_cidrs" {
  description = <<-DESC
    CIDRs a los que el SG permite reenviar paquetes. El default 10.0.0.0/8 cubre
    los workloads via TGW; un router dentro de otra VPC necesita el CIDR de esa VPC.
  DESC
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "grant_ingress_from_router" {
  description = <<-DESC
    SGs preexistentes que deben aceptar trafico desde el SG del router. Cada
    entrada agrega una regla de ingress en ESE SG con el del router como origen.
    Los IDs son literales: esos SGs no los maneja este modulo.
  DESC
  type = list(object({
    security_group_id = string
    from_port         = number
    to_port           = number
    protocol          = string
    description       = string
  }))
  default = []
}
