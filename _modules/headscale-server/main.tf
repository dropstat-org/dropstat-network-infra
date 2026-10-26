# ============================================================
# _modules/headscale-server
#
# Headscale — self-hosted Tailscale control plane.
# Corre en una subnet pública del egress VPC (Network account).
# Los clientes (laptops) se conectan via HTTPS al Elastic IP.
# El subnet router se registra aquí en vez de en Tailscale SaaS.
#
# Stack:
#   - Headscale (control plane, port 8080)
#   - Caddy (reverse proxy HTTPS, port 443 → 8080)
#   - SQLite (base de datos embebida, simple para <50 usuarios)
#   - Elastic IP (IP pública estable)
#
# Identidad y ACL:
#   Login por OIDC contra Cognito `dropstat-sso` (us-east-2_YzFtEJry5), que
#   federa Identity Center por SAML. Con strip_email_domain=false el usuario de
#   Headscale ES el email, y eso es lo que referencian las ACL.
#   El mapping SAML trae solo {email, username}: NO trae grupos de Identity
#   Center, asi que `group:devops` se declara en var.devops_members.
#   Con enforce_oidc=true no se crea el usuario compartido `vpn`: un nodo
#   registrado con preauth key no tiene identidad y ninguna ACL lo alcanza.
#
# Post-apply:
#   1. Validar la policy antes de confiar en ella:
#      aws ssm start-session --target <instance-id>
#      headscale policy check --file /etc/headscale/acl.hujson
#   2. Aprobar rutas de cada subnet router:
#      headscale routes list
#      headscale routes enable -r <route-id>
#   3. Cada persona entra con `tailscale up --login-server=<url>` y completa
#      el login en el navegador. No hay que crear usuarios a mano.
#
# OJO: user_data_replace_on_change = true. Tocar la ACL o el config RECREA la
# instancia. La db.sqlite vive en un EBS aparte y sobrevive, pero hay unos
# minutos sin control plane: los nodos ya conectados siguen (WireGuard es
# peer-to-peer), los logins nuevos fallan.
# ============================================================

module "account" {
  source = "git::https://github.com/dropstat-org/tm-aws-account-data.git?ref=master"
}

locals {
  tags = merge(var.tags, { Module = "headscale-server" })
  public_subnet_ids = [for s in module.account.subnets.publics : s.id]
  # FQDN del control plane: nombre del cert de Caddy, --login-server de los
  # nodos y host del callback OIDC, los tres a la vez.
  #
  # domain_name seteado = nombre propio, servido por la zona que crea el modulo
  # vpn-dns y delegada desde GoDaddy (el apex dropstat.com vive ahi). Esto
  # desacopla las tres cosas de la EIP: el 2026-10-25 un cambio de IP las
  # desalineo y dejo a todos afuera con error=redirect_mismatch. Antes de
  # setearlo, la delegacion NS tiene que existir y el nombre resolver desde
  # afuera a la EIP; adelantarlo deja a Caddy sin completar el ACME y tira la
  # VPN.
  #
  # vacio = forma anterior, derivada de la EIP via nip.io. Se usa la variante
  # con guiones (52-14-172-37.nip.io) y no la de puntos: el rate limit de ACME
  # es "5 certificados por set exacto de nombres en 168h" y la forma con puntos
  # quedo quemada el 2026-10-25, cuando tumbo la VPN. Lo que evita que vuelva a
  # pasar es persistir el cache de Caddy (abajo).
  fqdn = var.domain_name != "" ? var.domain_name : "${replace(aws_eip.headscale.public_ip, ".", "-")}.nip.io"
  # ── ACL policy (HuJSON) ─────────────────────────────────────────────────────
  # Default-deny: Headscale niega todo lo que no se acepte explicitamente.
  # Sin este archivo Headscale corre allow-all y cualquier nodo alcanza todo lo
  # que los subnet routers anuncien.
  # Headscale matchea los miembros de un grupo contra el NOMBRE del usuario, no
  # contra un email: en v0.23 la tabla users solo tiene `name`. Con
  # strip_email_domain = false el nombre que genera OIDC es el email con la @
  # cambiada por punto (randy.goz@dropstat.com -> randy.goz.dropstat.com), asi
  # que hay que aplicar la misma normalizacion o el grupo queda vacio.
  devops_users = [for m in var.devops_members : replace(m, "@", ".")]

  # autoApprovers aprueba las rutas que anuncia un subnet router sin pasar por
  # `headscale routes enable`. Importa porque el router corre en un ASG: cuando
  # la instancia se repone el nodo es nuevo y las rutas vuelven a quedar sin
  # aprobar, o sea que el acceso se cae hasta que alguien corra el comando a
  # mano. Esto no relaja nada: quien restringe el acceso es el bloque acls de
  # abajo; aprobar una ruta solo habilita al router a anunciar ese CIDR.
  # El match es por el DUEÑO del nodo, no por grupo de acceso: el router se
  # registra con preauth key de var.router_user, asi que va ese usuario y no
  # group:devops.
  auto_approved_routes = {
    for c in concat(var.prod_cidrs, var.nonprod_cidrs) : c => [var.router_user]
  }

  acl_policy = jsonencode({
    groups = {
      "group:devops" = local.devops_users
    }
    autoApprovers = {
      routes = local.auto_approved_routes
    }
    acls = concat(
      # prod: solo devops
      length(var.prod_cidrs) > 0 ? [{
        action = "accept"
        src    = ["group:devops"]
        dst    = [for c in var.prod_cidrs : "${c}:*"]
      }] : [],
      # no-prod: cualquier usuario autenticado
      length(var.nonprod_cidrs) > 0 ? [{
        action = "accept"
        src    = ["*"]
        dst    = [for c in var.nonprod_cidrs : "${c}:*"]
      }] : [],
      # malla entre nodos de la propia VPN (100.64.0.0/10)
      [{
        action = "accept"
        src    = ["*"]
        dst    = ["100.64.0.0/10:*"]
      }],
    )
  })

}

data "aws_subnet" "headscale" {
  id = local.public_subnet_ids[0]
}

# ── Elastic IP — IP pública estable ──────────────────────────────────────────

resource "aws_eip" "headscale" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-headscale" })
}

resource "aws_eip_association" "headscale" {
  instance_id   = module.ec2.id
  allocation_id = aws_eip.headscale.id
}

# ── EBS — almacenamiento persistente para /var/lib/headscale ────────────────
# Sobrevive a la recreación de la instancia (user_data_replace_on_change).
# DB sqlite + claves privadas de Headscale viven aquí.

resource "aws_ebs_volume" "headscale_data" {
  availability_zone = data.aws_subnet.headscale.availability_zone
  size               = 5
  type               = "gp3"
  encrypted          = true

  tags = merge(local.tags, { Name = "${var.name}-headscale-data" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "headscale_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.headscale_data.id
  instance_id = module.ec2.id
}

# ── Secrets Manager — OIDC client secret (Cognito broker, dropstat-aws-sso) ──
# Creado y poblado por dropstat-secrets-config (live/network/secrets), no aquí —
# evita que dos states distintos disputen el mismo nombre de secreto. El
# `removed` block libera este resource del state de este módulo SIN destruir
# el secreto físico (ya adoptado/importado por secrets-config).

removed {
  from = aws_secretsmanager_secret.oidc

  lifecycle {
    destroy = false
  }
}

data "aws_secretsmanager_secret" "oidc" {
  name = "${var.name}/headscale/oidc"
}

# ── Security group ────────────────────────────────────────────────────────────

module "sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.name}-headscale-server"
  description = "Headscale control plane - HTTPS inbound + WireGuard UDP"
  vpc_id      = module.account.vpc.id

  ingress_with_cidr_blocks = [
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "HTTPS - Tailscale clients + web UI"
    },
    {
      from_port   = 3478
      to_port     = 3478
      protocol    = "udp"
      cidr_blocks = "0.0.0.0/0"
      description = "STUN - NAT traversal para WireGuard"
    },
    # Sin ingress en el 80: el control plane solo se habla por HTTPS. Los nodos
    # nunca usan el 80 - ahi Caddy solo devolvia un 308 al 443. El ACME se
    # valida por tls-alpn-01, sobre el 443 (ver el Caddyfile del user_data);
    # cerrar el 80 sin desactivar el http challenge deja a Caddy sin poder
    # renovar y la VPN se cae al vencer el cert.
    {
      from_port   = -1
      to_port     = -1
      protocol    = "icmp"
      cidr_blocks = "100.64.0.0/10"
      description = "ICMP from Tailscale clients for connectivity testing"
    },
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "All outbound"
    },
  ]

  tags = local.tags
}

# ── IAM role — SSM + Secrets Manager ─────────────────────────────────────────

resource "aws_iam_role" "headscale" {
  name        = "${var.name}-headscale-server"
  description = "Headscale server - SSM access + read OIDC credentials"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.headscale.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secrets" {
  name = "read-headscale-oidc"
  role = aws_iam_role.headscale.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = data.aws_secretsmanager_secret.oidc.arn
    }]
  })
}

resource "aws_iam_instance_profile" "headscale" {
  name = "${var.name}-headscale-server"
  role = aws_iam_role.headscale.name
  tags = local.tags
}

# ── AMI ───────────────────────────────────────────────────────────────────────

# El AMI lo construye el repo dropstat-aws-runner-ami-deploy
# (packer/headscale.pkr.hcl) y publica su id en este parametro. Trae horneados
# los binarios de headscale y caddy, asi que el user_data ya no baja nada de
# internet para arrancar.
#
# Antes aca habia un `data "aws_ami"` con most_recent = true sobre las imagenes
# de Amazon Linux: cada vez que Amazon publicaba una AL2023 nueva, el proximo
# apply reemplazaba la instancia aunque el cambio fuera en otro modulo. Paso
# exactamente eso el 2026-10-25 con un apply que solo tocaba los routers.
# Leer un parametro fijo deja el reemplazo atado a un build explicito del AMI.
data "aws_ssm_parameter" "headscale_ami" {
  name = var.ami_ssm_parameter
}

# ── EC2 ───────────────────────────────────────────────────────────────────────

module "ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.0"

  name          = "${var.name}-headscale-server"
  instance_type = var.instance_type
  ami           = data.aws_ssm_parameter.headscale_ami.value

  # Subnet pública — necesita IP pública para que los clientes se conecten
  subnet_id                   = local.public_subnet_ids[0]
  vpc_security_group_ids      = [module.sg.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.headscale.name
  associate_public_ip_address = true   # reemplazado por Elastic IP

  key_name = null  # sin key pair, solo SSM

  user_data = base64encode(<<-EOF
#!/bin/bash
set -e

# Los binarios de headscale y caddy, y el usuario de sistema headscale, vienen
# en el AMI. Este script ya no baja nada de internet: solo arma la config y
# arranca los servicios.
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# ── Obtener credenciales OIDC desde Secrets Manager ──────────────────────
OIDC_JSON=$(aws secretsmanager get-secret-value \
  --secret-id ${data.aws_secretsmanager_secret.oidc.name} \
  --region "$REGION" --query SecretString --output text 2>/dev/null || echo '{}')
OIDC_CLIENT_ID=$(echo "$OIDC_JSON"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('client_id',''))")
OIDC_CLIENT_SECRET=$(echo "$OIDC_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('client_secret',''))")

# El binario y el usuario los provee el AMI. Si falta alguno de los dos, el
# AMI es el equivocado y es mejor cortar aca que dejar el servicio en crash
# loop sin explicacion.
test -x /usr/local/bin/headscale
test -x /usr/local/bin/caddy
id headscale >/dev/null

cat > /etc/systemd/system/headscale.service << 'UNITEOF'
[Unit]
Description=headscale controller
After=network.target

[Service]
Type=simple
User=headscale
Group=headscale
RuntimeDirectory=headscale
ExecStart=/usr/local/bin/headscale serve
Restart=always
RestartSec=5
WorkingDirectory=/var/lib/headscale

[Install]
WantedBy=multi-user.target
UNITEOF

# ── Configurar Headscale ──────────────────────────────────────────────────
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

mkdir -p /etc/headscale /var/lib/headscale

# ── Montar volumen EBS persistente en /var/lib/headscale ─────────────────
for i in $(seq 1 30); do
  DEVICE=$(readlink -f /dev/sdf 2>/dev/null || readlink -f /dev/xvdf 2>/dev/null || true)
  [ -n "$DEVICE" ] && [ -e "$DEVICE" ] && break
  sleep 2
done
if ! blkid "$DEVICE" >/dev/null 2>&1; then
  mkfs -t ext4 "$DEVICE"
fi
grep -q "$DEVICE" /etc/fstab || echo "$DEVICE /var/lib/headscale ext4 defaults,nofail 0 2" >> /etc/fstab
mount /var/lib/headscale
chown -R headscale:headscale /var/lib/headscale

cat > /etc/headscale/config.yaml << HSCFG
server_url: https://${local.fqdn}
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 0.0.0.0:50443
grpc_allow_insecure: false

private_key_path: /var/lib/headscale/private.key
noise:
  private_key_path: /var/lib/headscale/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48

derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default

disable_check_updates: true
# Cuanto espera el server antes de borrar un nodo ephemeral desconectado. Los
# routers se registran con keys ephemeral para no dejar nodos muertos
# acumulados (ver _modules/tailscale-router). Esta ventana es el trade-off: muy
# corta y un corte de red transitorio borra el router y con el su ruta Primary;
# muy larga y el nodo viejo sigue colisionando el hostname del nuevo durante el
# replace del ASG. 30m cubre un replace completo con margen, y el sufijo random
# del hostname mientras tanto es cosmetico.
ephemeral_node_inactivity_timeout: 30m

database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite

log:
  level: info

dns:
  magic_dns: true
  base_domain: vpn.dropstat.internal
  nameservers:
    global:
      - 1.1.1.1

policy:
  mode: file
  path: /etc/headscale/acl.hujson

oidc:
  only_start_if_oidc_is_available: ${var.enforce_oidc}
  issuer: https://cognito-idp.us-east-2.amazonaws.com/us-east-2_YzFtEJry5
  client_id: $OIDC_CLIENT_ID
  client_secret: $OIDC_CLIENT_SECRET
  scope: [openid, profile, email]
  allowed_domains:
    - dropstat.com
  strip_email_domain: false

  # Cuanto vale una sesion antes de pedir login OIDC de nuevo.
  #
  # Es un valor por SERVIDOR, no por destino: un nodo tiene la key valida o no
  # la tiene, y la ACL decide a donde llega. No se puede pedir 4h para prod y
  # 8h para dev con un solo control plane, asi que manda el mas estricto.
  #
  # No afecta a los routers: se registran con preauth keys, no por OIDC, y las
  # rutas de subnet no se renuevan cada ${var.oidc_session_expiry}.
  expiry: ${var.oidc_session_expiry}
HSCFG

# ── ACL policy ────────────────────────────────────────────
cat > /etc/headscale/acl.hujson << 'ACLEOF'
${local.acl_policy}
ACLEOF

chown -R headscale:headscale /etc/headscale

# ── Caddy (reverse proxy HTTPS) — el binario viene en el AMI ──────────────
cat > /etc/systemd/system/caddy.service << 'CADDYUNITEOF'
[Unit]
Description=Caddy
After=network.target
RequiresMountsFor=/var/lib/headscale

[Service]
Type=simple
# Caddy guarda los certs bajo $XDG_DATA_HOME/caddy. Por defecto eso cae en el
# disco raiz, que se pierde en cada replace de la instancia: con
# user_data_replace_on_change = true cualquier edicion de la ACL recrea la EC2
# y Caddy pide un cert nuevo. Cinco ediciones en una semana agotan el rate
# limit de Let's Encrypt y el handshake TLS empieza a devolver
# "tls: internal error", con lo cual ningun nodo puede registrarse. Apuntarlo
# al volumen EBS hace que el cert sobreviva al replace y no se vuelva a pedir.
Environment=XDG_DATA_HOME=/var/lib/headscale/caddy-data
Environment=XDG_CONFIG_HOME=/var/lib/headscale/caddy-config
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CADDYUNITEOF

mkdir -p /etc/caddy
# Sobre el EBS, no sobre el disco raiz (ver el unit de arriba). Caddy corre
# como root en este unit, asi que no se le cambia el dueno a headscale.
mkdir -p /var/lib/headscale/caddy-data /var/lib/headscale/caddy-config

cat > /etc/caddy/Caddyfile << CADDYEOF
{
  # El 80 esta cerrado en el security group, asi que no hay redirect que
  # servir ni challenge HTTP-01 que completar. Sin esto Caddy intenta
  # escuchar en el 80 y usar HTTP-01 primero, y el ACME queda colgado.
  auto_https disable_redirects
}

${local.fqdn} {
  tls {
    issuer acme {
      disable_http_challenge
    }
  }
  reverse_proxy localhost:8080
}
CADDYEOF

# ── Arrancar servicios ────────────────────────────────────────────────────
systemctl enable headscale caddy
systemctl start  headscale caddy

# ── Usuarios ───────────────────────────────────────────────
sleep 3

# `routers` ─ los subnet routers no pueden entrar por OIDC: son EC2 y se
# registran con preauth key. Este usuario existe siempre, y la ACL no le da
# ningun src (solo anuncia rutas, no inicia trafico).
headscale users create ${var.router_user} 2>/dev/null || true

# `vpn` ─ usuario humano compartido, sin identidad individual. Con
# enforce_oidc = true no se crea: cada persona entra por OIDC con su email.
%{ if !var.enforce_oidc ~}
headscale users create vpn 2>/dev/null || true
%{ endif ~}

# ── Reclamar la flag Primary de las rutas ─────────────────────────────────
#
# Cuando se reemplaza esta instancia, los routers vuelven a registrarse pero
# las filas de ruta viejas siguen en la db.sqlite del EBS, apuntando al node
# record anterior. Ese node queda offline para siempre y se queda con la flag
# Primary. Sin nadie que la tenga vigente, los clientes NO instalan la ruta:
# la VPN deja de llegar a esas subnets aunque el router este sano.
#
# Paso el 2026-10-25: las cinco rutas de prod (172.31.1-5.0/24) quedaron en
# Primary = false y prod se volvio inalcanzable. El sintoma enganosa: el
# router se ve "online" con un Last seen viejo y todo parece normal.
#
# El disable/enable fuerza a headscale a re-evaluar el failover y asignarle
# Primary a un node conectado. Solo se toca un prefijo si NINGUNA de sus
# filas tiene Primary: si ya hay una, es failover legitimo y no se interfiere.
#
# Va como timer y no como paso de arranque porque los routers se re-registran
# DESPUES de que el server esta arriba: al terminar el user_data todavia no
# hay rutas que arreglar. El timer tambien cubre los reemplazos de router.
cat > /usr/local/bin/headscale-primary-reconcile << 'RECONCILEEOF'
#!/usr/bin/python3
import collections
import json
import subprocess
import sys

HS = "/usr/local/bin/headscale"


def routes():
    out = subprocess.run(
        [HS, "routes", "list", "-o", "json"],
        capture_output=True, text=True, check=True,
    ).stdout
    # La salida JSON de protobuf omite los booleanos en false, asi que todo
    # chequeo va con .get(k, False) y no con indexado directo.
    return json.loads(out) or []


def main():
    by_prefix = collections.defaultdict(list)
    for r in routes():
        if r.get("advertised") and r.get("enabled"):
            by_prefix[r["prefix"]].append(r)

    orphaned = []
    for prefix, rows in by_prefix.items():
        if any(r.get("is_primary") for r in rows):
            continue
        for r in rows:
            rid = str(r["id"])
            subprocess.run([HS, "routes", "disable", "-r", rid],
                           capture_output=True, check=False)
            subprocess.run([HS, "routes", "enable", "-r", rid],
                           capture_output=True, check=False)
        orphaned.append(prefix)

    if not orphaned:
        return 0

    recovered = {r["prefix"] for r in routes() if r.get("is_primary")}
    rc = 0
    for prefix in orphaned:
        if prefix in recovered:
            print("reclaimed Primary for %s" % prefix)
        else:
            print("STILL ORPHANED: %s" % prefix, file=sys.stderr)
            rc = 1
    return rc


sys.exit(main())
RECONCILEEOF
chmod 0755 /usr/local/bin/headscale-primary-reconcile

cat > /etc/systemd/system/headscale-primary-reconcile.service << 'RECONCILEUNITEOF'
[Unit]
Description=Reclaim orphaned Primary flags on Headscale subnet routes
After=headscale.service
Requires=headscale.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/headscale-primary-reconcile
RECONCILEUNITEOF

cat > /etc/systemd/system/headscale-primary-reconcile.timer << 'RECONCILETIMEREOF'
[Unit]
Description=Reclaim orphaned Primary flags on Headscale subnet routes

[Timer]
OnBootSec=60
OnUnitActiveSec=120
AccuracySec=10

[Install]
WantedBy=timers.target
RECONCILETIMEREOF

systemctl daemon-reload
systemctl enable --now headscale-primary-reconcile.timer

echo "Headscale ready at https://$PUBLIC_IP"
EOF
  )

  user_data_replace_on_change = true
  tags = local.tags
}
