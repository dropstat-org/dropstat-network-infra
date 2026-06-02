# ============================================================
# _modules/tailscale-router
#
# Tailscale subnet router HA — acceso privado a todas las
# cuentas AWS via Transit Gateway.
#
# Arquitectura:
#   ASG min=2 max=2, una instancia por AZ (us-east-2a/2b)
#   Anuncia 10.0.0.0/8 → cubre dev, staging, prod, shared-services
#   Tailscale hace failover automático entre las dos instancias
#
# Auth: Tailscale auth key en Secrets Manager (reusable, sin expiración)
# Acceso: SSM Session Manager — sin key pair, sin SSH, sin inbound
#
# Post-apply:
#   1. Cargar auth key: aws secretsmanager put-secret-value --secret-id <name> --secret-string "tskey-auth-XXX"
#   2. Aprobar rutas en admin.tailscale.com → Routes → 10.0.0.0/8 → Enable
# ============================================================

module "account" {
  source = "git::https://github.com/dropstat-org/tm-aws-account-data.git?ref=master"
}

locals {
  tags = merge(var.tags, { Module = "tailscale-router" })

  # Subnets de red (tgw-attachment) — una por AZ para HA
  network_subnet_ids = [for s in module.account.subnets.networks : s.id]
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
  vpc_id      = module.account.vpc.id

  egress_with_cidr_blocks = [
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
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "10.0.0.0/8"
      description = "Forward packets to all workload accounts via TGW"
    },
  ]

  tags = local.tags
}

# ── AMI — Amazon Linux 2023 ───────────────────────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
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

  # Sin key pair — acceso exclusivamente via SSM
  key_name = null

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # IP forwarding (requerido para subnet router)
    echo 'net.ipv4.ip_forward = 1'           >> /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1'  >> /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf

    # Instalar Tailscale (cliente — compatible con Headscale)
    curl -fsSL https://tailscale.com/install.sh | sh

    # Obtener auth key desde Secrets Manager
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
    AUTH_KEY=$(aws secretsmanager get-secret-value \
      --secret-id ${aws_secretsmanager_secret.authkey.name} \
      --region "$REGION" \
      --query SecretString \
      --output text)

    # Registrar en Headscale como subnet router
    # --login-server apunta al servidor Headscale propio en vez de Tailscale SaaS
    AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
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

# ── Auto Scaling Group — min=2 max=2, una instancia por AZ ───────────────────

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 8.0"

  name = "${var.name}-tailscale-router"

  # Fixed size — siempre 2 instancias, sin scaling dinámico
  min_size         = 2
  max_size         = 2
  desired_capacity = 2

  # Una instancia por AZ para HA real
  vpc_zone_identifier = local.network_subnet_ids

  # Launch template gestionado arriba
  create_launch_template = false
  launch_template_id     = aws_launch_template.tailscale.id
  launch_template_version = "$Latest"

  # Instance refresh — rolling update cuando cambia el launch template
  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 50   # mantiene 1 instancia up durante el update
    }
  }

  # Health check — EC2 level (no ELB, el router no tiene load balancer)
  health_check_type         = "EC2"
  health_check_grace_period = 120

  tags = local.tags
}
