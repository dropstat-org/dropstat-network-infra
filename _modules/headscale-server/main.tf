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
# Post-apply:
#   1. Aprobar el subnet router:
#      aws ssm start-session --target <instance-id>
#      headscale nodes register --user vpn --key <node-key>
#   2. Aprobar rutas del router:
#      headscale routes enable -r <route-id>
#   3. Agregar usuarios:
#      headscale users create <email>
#      headscale --user <email> preauthkeys create --reusable --expiration 1h
# ============================================================

module "account" {
  source = "git::https://github.com/dropstat-org/tm-aws-account-data.git?ref=master"
}

locals {
  tags = merge(var.tags, { Module = "headscale-server" })
  public_subnet_ids = [for s in module.account.subnets.publics : s.id]
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

# ── Secrets Manager — OIDC client secret para Google SSO ─────────────────────
# Cargar manualmente:
#   aws secretsmanager put-secret-value \
#     --secret-id <secret_name> \
#     --secret-string '{"client_id":"xxx","client_secret":"yyy"}'

resource "aws_secretsmanager_secret" "oidc" {
  name                    = "${var.name}/headscale/oidc"
  description             = "Google OIDC credentials for Headscale SSO"
  recovery_window_in_days = 0
  tags                    = local.tags
}

# ── Security group ────────────────────────────────────────────────────────────

module "sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.name}-headscale-server"
  description = "Headscale control plane — HTTPS inbound + WireGuard UDP"
  vpc_id      = module.account.vpc.id

  ingress_with_cidr_blocks = [
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "HTTPS — Tailscale clients + web UI"
    },
    {
      from_port   = 3478
      to_port     = 3478
      protocol    = "udp"
      cidr_blocks = "0.0.0.0/0"
      description = "STUN — NAT traversal para WireGuard"
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
      Resource = aws_secretsmanager_secret.oidc.arn
    }]
  })
}

resource "aws_iam_instance_profile" "headscale" {
  name = "${var.name}-headscale-server"
  role = aws_iam_role.headscale.name
  tags = local.tags
}

# ── AMI ───────────────────────────────────────────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name";  values = ["al2023-ami-*-x86_64"] }
  filter { name = "state"; values = ["available"] }
}

# ── EC2 ───────────────────────────────────────────────────────────────────────

module "ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  name          = "${var.name}-headscale-server"
  instance_type = var.instance_type
  ami           = data.aws_ami.al2023.id

  # Subnet pública — necesita IP pública para que los clientes se conecten
  subnet_id                   = local.public_subnet_ids[0]
  vpc_security_group_ids      = [module.sg.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.headscale.name
  associate_public_ip_address = true   # reemplazado por Elastic IP

  key_name = null  # sin key pair, solo SSM

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

    # ── Obtener credenciales OIDC desde Secrets Manager ──────────────────────
    OIDC_JSON=$(aws secretsmanager get-secret-value \
      --secret-id ${aws_secretsmanager_secret.oidc.name} \
      --region "$REGION" --query SecretString --output text 2>/dev/null || echo '{}')
    OIDC_CLIENT_ID=$(echo "$OIDC_JSON"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('client_id',''))")
    OIDC_CLIENT_SECRET=$(echo "$OIDC_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('client_secret',''))")

    # ── Instalar Headscale ────────────────────────────────────────────────────
    HEADSCALE_VERSION="0.23.0"
    curl -fsSLo /tmp/headscale.rpm \
      "https://github.com/juanfont/headscale/releases/download/v$HEADSCALE_VERSION/headscale_$${HEADSCALE_VERSION}_linux_amd64.rpm"
    rpm -i /tmp/headscale.rpm

    # ── Configurar Headscale ──────────────────────────────────────────────────
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

    mkdir -p /etc/headscale /var/lib/headscale

    cat > /etc/headscale/config.yaml << HSCFG
server_url: https://$PUBLIC_IP
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 0.0.0.0:50443
grpc_allow_insecure: false

private_key_path: /var/lib/headscale/private.key
noise:
  private_key_path: /var/lib/headscale/noise_private.key

ip_prefixes:
  - 100.64.0.0/10

derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default

disable_check_updates: true
ephemeral_node_inactivity_timeout: 30m

database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite

log:
  level: info

dns_config:
  magic_dns: true
  base_domain: vpn.dropstat.internal
  nameservers:
    - 1.1.1.1

oidc:
  only_start_if_oidc_is_available: false
  issuer: https://accounts.google.com
  client_id: $OIDC_CLIENT_ID
  client_secret: $OIDC_CLIENT_SECRET
  scope: [openid, profile, email]
  allowed_domains:
    - dropstat.com
  strip_email_domain: false
HSCFG

    # ── Instalar Caddy (reverse proxy HTTPS) ──────────────────────────────────
    dnf install -y 'dnf-command(copr)'
    dnf copr enable -y @caddy/caddy
    dnf install -y caddy 2>/dev/null || \
      (curl -fsSLo /tmp/caddy.rpm \
        "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_amd64.rpm" && \
       rpm -i /tmp/caddy.rpm)

    cat > /etc/caddy/Caddyfile << CADDYEOF
:443 {
  reverse_proxy localhost:8080
  tls internal
}
CADDYEOF

    # ── Arrancar servicios ────────────────────────────────────────────────────
    systemctl enable headscale caddy
    systemctl start  headscale caddy

    # ── Crear usuario vpn por defecto ─────────────────────────────────────────
    sleep 3
    headscale users create vpn 2>/dev/null || true

    echo "Headscale ready at https://$PUBLIC_IP"
  EOF
  )

  user_data_replace_on_change = true
  tags = local.tags
}
