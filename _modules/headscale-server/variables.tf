variable "name" {
  description = "Nombre base para todos los recursos (e.g. 'dropstat')"
  type        = string
}

variable "instance_type" {
  description = "Tipo de instancia. t3.small recomendado para <50 usuarios."
  type        = string
  default     = "t3.small"
}

variable "ami_ssm_parameter" {
  description = <<-EOT
    Parametro de SSM que guarda el id del AMI de Headscale. Lo escribe el
    workflow build-headscale-ami.yml de dropstat-aws-runner-ami-deploy.
    Cambiar su valor reemplaza la instancia en el proximo apply.
  EOT
  type        = string
  default     = "/dropstat/headscale/ami-id"
}

variable "oidc_session_expiry" {
  description = <<-EOT
    Cuanto vale una sesion autenticada por OIDC antes de pedir login otra vez.
    Es global al servidor: no se puede diferenciar por ambiente, asi que el
    valor es el que pide prod. Cambiarlo RECREA la instancia (va en el
    user_data). "0" desactiva la expiracion.
  EOT
  type        = string
  default     = "4h"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ── ACL policy ────────────────────────────────────────────────────────────────
# Headscale 0.23 lee la policy UNA VEZ al arrancar. Como el config se escribe en
# el user_data y la instancia tiene user_data_replace_on_change = true, cambiar
# estas variables RECREA la instancia. El volumen EBS es aparte, asi que la
# db.sqlite (usuarios, nodos, rutas aprobadas) sobrevive.

variable "devops_members" {
  description = <<-DESC
    Emails de quienes pueden alcanzar prod_cidrs. Se traducen al nombre de
    usuario de Headscale reemplazando la @ por punto (ver local.devops_users):
    con strip_email_domain=false el usuario NO es el email, es
    randy.goz.dropstat.com. El grupo matchea por nombre y en v0.23 la tabla
    users no guarda email.

    Cada persona tiene que haber entrado al menos una vez por OIDC para que el
    usuario exista; si no, su entrada del grupo no matchea nada.

    El mapping SAML del IdP solo trae {email, username}, no grupos de Identity
    Center, asi que la membresia se declara aqui y no se hereda.
  DESC
  type        = list(string)
}

variable "prod_cidrs" {
  description = "CIDRs de prod. Solo devops_members los alcanza."
  type        = list(string)
  default     = []
}

variable "nonprod_cidrs" {
  description = "CIDRs abiertos a cualquier usuario autenticado (dev, qa, shared)."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "enforce_oidc" {
  description = <<-DESC
    true: Headscale no arranca sin OIDC y no se crea el usuario compartido `vpn`.
    Las ACL por usuario solo funcionan si cada persona entra como si misma — un
    nodo registrado con preauth key del usuario `vpn` no tiene identidad propia.
    Dejarlo en false mantiene el camino de preauth key y vuelve la ACL inutil.
  DESC
  type        = bool
  default     = true
}

variable "router_user" {
  description = <<-DESC
    Usuario de Headscale al que pertenecen los subnet routers. Se crea siempre,
    tambien con enforce_oidc = true: un EC2 no puede hacer el flujo OIDC, se
    registra con preauth key de este usuario.
  DESC
  type        = string
  default     = "routers"
}
