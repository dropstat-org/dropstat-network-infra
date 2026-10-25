# ============================================================
# _modules/tailscale-router
#
# Tailscale subnet router HA — acceso privado a todas las
# cuentas AWS via Transit Gateway.
#
# Arquitectura:
#   ASG min=1 max=1 — NO hay HA hoy. Una sola instancia: si se cae, se pierde
#   el acceso hasta que el ASG la reponga. Subirlo a min=2/max=2 (una por AZ)
#   da failover real, Tailscale elige entre routers que anuncian lo mismo.
#   advertise_routes decide el alcance; ver la variable.
#
# Auth: Tailscale auth key en Secrets Manager (reusable, sin expiración)
# Acceso: SSM Session Manager — sin key pair, sin SSH, sin inbound
#
# Post-apply:
#   1. Cargar auth key: aws secretsmanager put-secret-value --secret-id <name> --secret-string "tskey-auth-XXX"
#   2. Las rutas se aprueban solas: los CIDRs anunciados estan en
#      autoApprovers de la policy (ver _modules/headscale-server). Verificar
#      con `headscale routes list`; solo hace falta `routes enable -r <id>` si
#      se anuncia un CIDR que no esta declarado ahi.
# ============================================================

# tm-aws-account-data resuelve SIEMPRE la cuenta network. Solo se consulta
# cuando no se pasa var.vpc_id, para que el modulo sirva en otras cuentas.
module "account" {
  count  = var.vpc_id == null ? 1 : 0
  source = "git::https://github.com/dropstat-org/tm-aws-account-data.git?ref=master"
}

# El router existente en la cuenta network tiene module.account sin count en el
# state. Sin esto, agregar count lo veria como destroy + create.
moved {
  from = module.account
  to   = module.account[0]
}

locals {
  tags = merge(var.tags, { Module = "tailscale-router" })

  # one() devuelve null cuando count = 0, y try() evita que la rama no usada del
  # condicional explote al recorrer ese null.
  account = one(module.account)

  vpc_id = coalesce(var.vpc_id, try(local.account.vpc.id, ""))

  # Subnets del ASG — una por AZ
  network_subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : try([for s in local.account.subnets.secures : s.id], [])
}

# ── Secrets Manager — Tailscale auth key ──────────────────────────────────────
# Cargar manualmente después del apply:
#   aws secretsmanager put-secret-value \
#     --secret-id <secret_name output> \
#     --secret-string "tskey-auth-XXXXXXXX"

resource "aws_secretsmanager_secret" "authkey" {
  name                    = "${var.name}/tailscale/auth-key"
  description             = "Tailscale reusable auth key for subnet routers. No expiry."
  recovery_window_in_days = 0
  tags                    = local.tags
}

# ── IAM role — SSM + Secrets Manager ─────────────────────────────────────────

resource "aws_iam_role" "tailscale" {
  name        = "${var.name}-tailscale-router"
  description = "Tailscale subnet router - SSM access + read auth key from Secrets Manager"

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
  role       = aws_iam_role.tailscale.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secrets" {
  name = "read-tailscale-authkey"
  role = aws_iam_role.tailscale.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadTailscaleAuthKey"
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.authkey.arn
    }]
  })
}

resource "aws_iam_instance_profile" "tailscale" {
  name = "${var.name}-tailscale-router"
  role = aws_iam_role.tailscale.name
  tags = local.tags
}

# ── Security group ────────────────────────────────────────────────────────────
# Sin inbound desde internet — Tailscale usa UDP 41641 outbound (WireGuard/STUN)

module "sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.name}-tailscale-router"
  description = "Tailscale subnet router - outbound only"
  vpc_id      = local.vpc_id

  egress_with_cidr_blocks = concat(
    [
      {
        from_port   = 41641
        to_port     = 41641
        protocol    = "udp"
        cidr_blocks = "0.0.0.0/0"
        description = "Tailscale WireGuard UDP"
      },
      {
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = "0.0.0.0/0"
        description = "Tailscale control plane HTTPS"
      },
    ],
    [
      for c in var.forward_cidrs : {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = c
        description = "Forward packets to ${c}"
      }
    ],
  )

  tags = local.tags
}

# ── AMI — Amazon Linux 2023 ───────────────────────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ── Launch template ───────────────────────────────────────────────────────────

resource "aws_launch_template" "tailscale" {
  name_prefix   = "${var.name}-tailscale-router-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.tailscale.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [module.sg.security_group_id]
    delete_on_termination       = true
  }

  # IMDSv2 obligatorio — IMDSv1 permite leer credenciales del rol via SSRF
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Sin key pair — acceso exclusivamente via SSM
  key_name = null

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # IP forwarding (requerido para subnet router)
    echo 'net.ipv4.ip_forward = 1'           >> /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1'  >> /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf

    # Swap antes de instalar: el install de Tailscale corre `yum install` y el
    # repo de AL2023 carga ~86MB de metadata, que en t3.nano (512MB, ~419
    # usables) mata al proceso por OOM y deja la instancia sin tailscaled.
    # Esto no se veia porque los routers llevaban meses arriba: se rompia solo
    # al reponer la instancia, o sea justo cuando el ASG tenia que servir.
    if ! swapon --show | grep -q /swapfile; then
      dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # Instalar Tailscale (cliente — compatible con Headscale)
    curl -fsSL https://tailscale.com/install.sh | sh

    # Obtener auth key desde Secrets Manager
    IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
    AUTH_KEY=$(aws secretsmanager get-secret-value \
      --secret-id ${aws_secretsmanager_secret.authkey.name} \
      --region "$REGION" \
      --query SecretString \
      --output text)

    # Registrar en Headscale como subnet router
    # --login-server apunta al servidor Headscale propio en vez de Tailscale SaaS
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    tailscale up \
      --login-server="${var.headscale_url}" \
      --authkey="$AUTH_KEY" \
      --advertise-routes=${var.advertise_routes} \
      --accept-dns=false \
      --hostname="${var.name}-router-$AZ"

    systemctl enable tailscaled
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.name}-tailscale-router" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

# ── Auto Scaling Group — min=1 max=1 ──────────────────────────────────────────

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 8.0"

  name = "${var.name}-tailscale-router"

  # Fixed size — 1 instancia, sin scaling dinámico
  min_size         = 1
  max_size         = 1
  desired_capacity = 1

  # Una instancia por AZ para HA real
  vpc_zone_identifier = local.network_subnet_ids

  # Launch template gestionado arriba.
  # Version explicita, NO "$Latest": con "$Latest" el recurso del ASG no cambia
  # cuando se edita el user_data, asi que terraform no tiene nada que
  # actualizar y el instance_refresh de abajo no se dispara nunca. El apply
  # publica la version nueva del launch template y no la rueda: la instancia
  # vieja sigue corriendo el user_data anterior hasta que alguien la termina a
  # mano. Pasó el 2026-10-25 con el fix de swap (LT v10 publicada, cero
  # refreshes en el historial del ASG).
  create_launch_template  = false
  launch_template_id      = aws_launch_template.tailscale.id
  launch_template_version = aws_launch_template.tailscale.latest_version

  # Instance refresh — rolling update cuando cambia el launch template.
  # Con min=max=1 no hay forma de mantener una instancia arriba durante el
  # reemplazo: el refresh termina la unica que hay y espera la nueva, o sea
  # ~2 min sin VPN. Es el precio de que el cambio se despliegue solo; subir a
  # min=2/max=2 (una por AZ) lo elimina.
  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 0
      instance_warmup        = 120
    }
  }

  # Health check — EC2 level (no ELB, el router no tiene load balancer)
  health_check_type         = "EC2"
  health_check_grace_period = 120

  tags = local.tags
}
