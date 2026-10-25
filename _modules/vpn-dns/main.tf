# Zona publica y registro A para el servidor Headscale.
#
# Hoy el FQDN se deriva de la Elastic IP via nip.io (ver _modules/headscale-server,
# local.fqdn). Eso acopla tres cosas a la IP: el cert de Let's Encrypt, el
# --login-server con el que se registran los routers, y el callback OIDC que
# declara dropstat-aws-sso. Cualquier cambio de EIP rompe las tres; el
# 2026-10-25 nos dejo a todos sin poder loguear con error=redirect_mismatch.
#
# Con un nombre propio el FQDN deja de moverse y la IP pasa a ser un detalle
# del registro A.
#
# El patron es el mismo que dev.dropstat.com y qa.dropstat.com:
# zona publica en la cuenta + delegacion NS manual en GoDaddy, que es donde
# esta registrado el apex dropstat.com.
#
# IMPORTANTE: este modulo NO cambia el FQDN de Headscale. Es aditivo. El
# cambio de local.fqdn va en un PR aparte y recien despues de que la
# delegacion resuelva: si se cambia antes, Caddy no completa el ACME HTTP-01,
# la VPN queda caida y se gasta uno de los 5 certs por semana.

resource "aws_route53_zone" "vpn" {
  name    = var.domain_name
  comment = var.comment
  tags    = merge(var.tags, { Name = var.domain_name })
}

resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.vpn.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = var.ttl
  records = [var.public_ip]
}
