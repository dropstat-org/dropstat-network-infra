> 🌐 [English](README.md)

# dropstat-network-infra

**Módulos Terraform** reutilizables para la infraestructura de red compartida de Dropstat:
el plano de control **Headscale** self-hosted y el **subnet router de Tailscale** en alta
disponibilidad que, juntos, dan acceso privado basado en identidad a todas las cuentas AWS
a través del Transit Gateway.

Este repositorio es **solo una librería de módulos** — no contiene state ni se aplica
directamente. Lo consume [`dropstat-network-deploy`](../dropstat-network-deploy) (la capa
de deploy con Terragrunt) vía
`github.com/dropstat-org/dropstat-network-infra//_modules/...?ref=main`.

---

## 1. Visión general y propósito

Dropstat corre una organización AWS multi-cuenta conectada por un Transit Gateway central
en la **cuenta network** (`027053844689`). Las personas y el CI necesitan acceso privado a
recursos en esas cuentas (Aurora, ECS, ALBs internos) sin exponer nada a internet y sin un
appliance de VPN corporativa pesado.

La solución es un **stack de Tailscale self-hosted**:

- **Headscale** — implementación open-source y self-hosted del plano de control de
  Tailscale. Corre en una sola instancia EC2 en el egress VPC y autentica usuarios vía
  Google OIDC. Sin dependencia del SaaS de Tailscale.
- **Tailscale subnet router** — un Auto Scaling Group (2 instancias, una por AZ) que
  anuncia `10.0.0.0/8` en la tailnet. Cualquier dispositivo unido a la tailnet alcanza
  todas las cuentas workload por el Transit Gateway, con failover automático de Tailscale
  entre las dos instancias del router.

Ambos módulos están diseñados para **cero inbound SSH**: la administración es exclusivamente
por AWS SSM Session Manager y los secretos se leen desde AWS Secrets Manager en el arranque.

Los módulos usan el módulo de descubrimiento compartido
`github.com/dropstat-org/tm-aws-account-data` para localizar el egress VPC y las subnets
correctamente etiquetadas en tiempo de apply, así que no requieren subnet IDs hardcodeados.

---

## 2. Diagrama de arquitectura

```
                          Internet
                             │
                             ▼
        ┌────────────────────────────────────────────────────────────┐
        │           Cuenta network  (dropstat-network, 027053844689)  │
        │                                                              │
        │   Egress VPC  10.0.0.0/24                                    │
        │   ┌───────────────────────────┐   ┌──────────────────────┐  │
        │   │ subnet pública(10.0.0.0/26)│  │ subnets network/tgw   │  │
        │   │                           │   │ (una por AZ)          │  │
        │   │  ┌─────────────────────┐  │   │  ┌────────────────┐   │  │
        │   │  │ headscale-server    │  │   │  │ tailscale-router│  │  │
        │   │  │ EC2 t3.small        │  │   │  │ ASG  2 × t3.nano│  │  │
        │   │  │ Elastic IP (estable)│  │   │  │ (2a + 2b)       │  │  │
        │   │  │ Caddy :443→:8080    │  │   │  │ anuncia         │  │  │
        │   │  │ Headscale + SQLite  │◄─┼───┼──│ 10.0.0.0/8      │  │  │
        │   │  └─────────────────────┘  │   │  └───────┬────────┘   │  │
        │   └───────────────────────────┘   └──────────┼───────────┘  │
        │                                              │              │
        │                              Transit Gateway │              │
        │                            tgw-089975dc3b606d95b            │
        └──────────────────────────────────────────────┼─────────────┘
                                                        │ 10.0.0.0/8
                  ┌─────────────────────────────────────┼──────────────────┐
                  ▼                      ▼               ▼                  ▼
          dev (10.1.0.0/18)   shared-svcs(10.0.1.0/24)  staging (futuro)  prod (futuro)
          Aurora / ECS / Redis   ECR / runners / SSO

   Laptop ──HTTPS──► Elastic IP de Headscale   (login vía Google OIDC)
   Laptop ──WireGuard──► tailnet ──► subnet router ──► TGW ──► cualquier cuenta
```

---

## 3. Estructura del repositorio

```
dropstat-network-infra/
├── README.md                      ← versión en inglés
├── README.es.md                   ← este archivo (español)
└── _modules/
    ├── headscale-server/          ← plano de control Tailscale self-hosted
    │   ├── main.tf                ← EIP, EC2, SG, IAM, Secrets Manager, user_data
    │   ├── variables.tf           ← name, instance_type, tags
    │   └── outputs.tf             ← public_ip, server_url, instance_id, oidc_secret_*
    └── tailscale-router/          ← subnet router HA (ASG)
        ├── main.tf                ← launch template, ASG, SG, IAM, Secrets Manager
        ├── variables.tf           ← name, instance_type, advertise_routes, headscale_url, tags
        └── outputs.tf             ← asg_name, secret_arn, secret_name, launch_template_id
```

---

## 4. Recursos gestionados

### Módulo `headscale-server`

| Recurso | Nombre / valor | Notas |
|---------|----------------|-------|
| `aws_eip.headscale` | `${name}-headscale` | IP pública estable para clientes |
| `aws_eip_association.headscale` | — | Asocia la EIP a la instancia EC2 |
| `module.ec2` (`terraform-aws-modules/ec2-instance ~> 5.0`) | `${name}-headscale-server` | `t3.small` por defecto, Amazon Linux 2023, subnet pública |
| `aws_secretsmanager_secret.oidc` | `${name}/headscale/oidc` | `client_id` / `client_secret` de Google OIDC (carga manual) |
| `module.sg` (`terraform-aws-modules/security-group ~> 5.0`) | `${name}-headscale-server` | Inbound 443/tcp (HTTPS) + 3478/udp (STUN); todo egress |
| `aws_iam_role.headscale` | `${name}-headscale-server` | SSM core + leer secret OIDC |
| `aws_iam_instance_profile.headscale` | `${name}-headscale-server` | — |

**Stack de software (vía user_data):** Headscale 0.23.0 (plano de control en `:8080`),
Caddy (reverse proxy HTTPS `:443 → :8080`, TLS interno), SQLite (DB embebida, suficiente
para < 50 usuarios). Rango de IPs de la tailnet `100.64.0.0/10`. Dominio base de MagicDNS
`vpn.dropstat.internal`. En el primer arranque se crea un usuario `vpn` por defecto.

### Módulo `tailscale-router`

| Recurso | Nombre / valor | Notas |
|---------|----------------|-------|
| `aws_secretsmanager_secret.authkey` | `${name}/tailscale/auth-key` | Auth key reusable de Tailscale, sin expiración (carga manual) |
| `aws_launch_template.tailscale` | `${name}-tailscale-router-` | Amazon Linux 2023, sin IP pública, sin key pair |
| `module.asg` (`terraform-aws-modules/autoscaling ~> 8.0`) | `${name}-tailscale-router` | `min=max=desired=2`, una por AZ, health check EC2, instance refresh rolling |
| `module.sg` (`terraform-aws-modules/security-group ~> 5.0`) | `${name}-tailscale-router` | **Solo outbound**: 41641/udp (WireGuard), 443/tcp (control plane), todo hacia `10.0.0.0/8` (forwarding) |
| `aws_iam_role.tailscale` | `${name}-tailscale-router` | SSM core + leer secret auth-key |
| `aws_iam_instance_profile.tailscale` | `${name}-tailscale-router` | — |

**Stack de software (vía user_data):** habilita IP forwarding IPv4/IPv6 (requerido para un
subnet router), instala el cliente Tailscale, obtiene el auth key de Secrets Manager y corre
`tailscale up --login-server=<headscale_url> --advertise-routes=10.0.0.0/8
--accept-dns=false`. Hostname `${name}-router-<az>`.

---

## 5. Proceso de attachment al Transit Gateway para cuentas nuevas

El TGW y sus attachments se gestionan en **platform-infra**, no aquí. Estos módulos de red
consumen el TGW solo indirectamente: el subnet router anuncia `10.0.0.0/8` para que **una
vez que la VPC de una cuenta se adjunta al TGW, sea automáticamente alcanzable por la VPN**
— sin cambios en estos módulos.

Para agregar una cuenta nueva a la red (resumen; proceso completo en
[`dropstat-network-deploy`](../dropstat-network-deploy) y platform-infra):

1. Crear la VPC de la cuenta con un CIDR `10.x.0.0/18` sin solapamiento (platform-infra
   `workloads/<env>/vpc/`). El módulo de VPC crea un attachment TGW en `pendingAcceptance`.
2. El módulo TGW de platform-infra (`network/transit-gateway/`) auto-descubre y acepta el
   attachment, y luego lo asocia a la route table del tier correcto.
3. Como el router ya anuncia `10.0.0.0/8`, el rango `10.x.x.x` de la cuenta nueva queda
   alcanzable de inmediato desde cualquier cliente VPN — **sin apply en este repo**.

> Si el rango anunciado por el router alguna vez necesita cambiar (p. ej. a un supernet más
> amplio o más estrecho), editá `advertise_routes` en `dropstat-network-deploy`, re-aplicá
> y re-habilitá la ruta en el admin de Headscale/Tailscale.

---

## 6. Setup de la VPN Headscale / Tailscale

### Bring-up del plano de control (una sola vez)

1. **Aplicar** `headscale-server` (vía `dropstat-network-deploy`). Crea la EIP, la
   instancia y el secret OIDC vacío.
2. **Cargar las credenciales OIDC de Google** en Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id dropstat/headscale/oidc \
     --secret-string '{"client_id":"xxx.apps.googleusercontent.com","client_secret":"yyy"}'
   ```
   El cliente OAuth de Google debe permitir el redirect URI
   `https://<elastic-ip>/oidc/callback` y estar restringido al dominio `dropstat.com`
   (`allowed_domains` en la config de Headscale).
3. Headscale lee el secret en el siguiente arranque (`user_data_replace_on_change = true`),
   así que re-aplicá o reemplazá la instancia después de cargar el secret.

### Poner el subnet router online

1. **Aplicar** `tailscale-router`. Crea el ASG y el secret de auth-key vacío.
2. **Generar un pre-auth key reusable** en el servidor Headscale (por SSM) y guardarlo:
   ```bash
   aws ssm start-session --target <headscale-instance-id>
   # en el servidor:
   headscale users create vpn                      # si no existe ya
   headscale --user vpn preauthkeys create --reusable --expiration 87600h
   ```
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id dropstat/tailscale/auth-key \
     --secret-string "<el-key-reusable>"
   ```
3. Disparar un instance refresh del ASG (o terminar las instancias) para que los routers se
   registren con el key nuevo.
4. **Aprobar las rutas anunciadas** en el servidor Headscale:
   ```bash
   headscale nodes list                            # encontrar los node IDs del router
   headscale routes list
   headscale routes enable -r <route-id>           # habilitar 10.0.0.0/8 por cada router
   ```

### Onboarding de un usuario final

```bash
# en el servidor Headscale (por SSM)
headscale users create alice@dropstat.com
```
El usuario corre `tailscale up --login-server=https://<elastic-ip>` en su laptop y
autentica vía Google. Tras unirse, conectarse con `--accept-routes` hace alcanzable todo
`10.0.0.0/8`. Camino verificado: MySQL Workbench desde un cliente Windows conectado a la VPN
hacia `dropstat-dev.cluster-...rds.amazonaws.com:3306`.

> Futuro: apuntar `dns_config.nameservers` de Headscale al resolver privado de la VPC para
> que los clientes resuelvan hostnames internos (RDS, ECS) directamente.

---

## 7. Convenciones de etiquetado de subnets (crítico para tm-aws-account-data)

Ningún módulo hardcodea subnet IDs. En su lugar llaman al módulo de descubrimiento:

```hcl
module "account" {
  source = "git::https://github.com/dropstat-org/tm-aws-account-data.git?ref=master"
}
```

y seleccionan subnets por su **categoría lógica**:

| Módulo | Selector | Dónde aterriza la instancia |
|--------|----------|-----------------------------|
| `headscale-server` | `module.account.subnets.publics` | Una subnet **pública** (necesita IP pública para clientes) |
| `tailscale-router` | `module.account.subnets.networks` | Las subnets **network / tgw-attachment**, una por AZ para HA |

Para que `tm-aws-account-data` clasifique estas subnets correctamente, las subnets de la
VPC **deben estar etiquetadas** al crearse en platform-infra. El egress VPC
(`_modules/network-hub`) las etiqueta:

| Propósito de la subnet | Tag en platform-infra | Descubierta como |
|------------------------|-----------------------|------------------|
| Pública (NAT + ALBs) | `subnet-type = public` | `subnets.publics` |
| ENIs del attachment TGW | `subnet-type = tgw-attachment` | `subnets.networks` |

Las VPCs workload (`_modules/workload-vpc`) usan los tags paralelos `subnet-type =
workload | data | secu`. **Si estos tags faltan o están mal, el descubrimiento devuelve
listas vacías y los módulos fallan en plan/apply.** Esta convención de etiquetado es el
contrato entre los módulos de red de aquí y las VPCs definidas en platform-infra.

---

## 8. Pipeline CI/CD

Este repositorio es una **librería de módulos** y no tiene pipeline propio — no hay nada que
aplicar. Los módulos se versionan por ref de Git (`?ref=main`) y se validan implícitamente
cuando el repo consumidor ([`dropstat-network-deploy`](../dropstat-network-deploy)) corre
`terragrunt plan`/`apply` a través del reusable workflow estándar de la org
(`dropstat-org/gha-actions-core-lib/.github/workflows/actions-core-lib.yml@main`).

Los cambios de aquí toman efecto cuando el repo de deploy fija/actualiza el ref y re-aplica.

---

## 9. Cómo agregar una cuenta nueva a la red

Desde la perspectiva de estos módulos, **no cambia nada** — el router anuncia todo el
supernet `10.0.0.0/8`, así que una cuenta recién adjuntada es alcanzable automáticamente.
El checklist end-to-end (abarca platform-infra y el repo de deploy):

1. **platform-infra** — agregar la cuenta (`common_vars.yaml` → `new_accounts`, `cidrs`,
   `workloads.<env>.tier`) y aplicar `management/organizations`, luego `workloads/<env>/vpc`.
2. **platform-infra** — el módulo TGW acepta el attachment y lo asocia a la route table del
   tier (auto-discovery). Asegurar que las subnets de la VPC nueva llevan los tags
   `subnet-type` (ver §7).
3. **Sin acción en este repo.** El subnet router ya cubre `10.x.x.x` vía la ruta anunciada
   `10.0.0.0/8`.
4. **Política VPN opcional** — para acotar qué usuarios/tags pueden alcanzar la cuenta
   nueva, actualizar las ACLs de Tailscale/Headscale (gestionadas operacionalmente en el
   servidor Headscale).

Si en algún momento dividís el supernet anunciado en rutas por ambiente, cambiá
`advertise_routes` en [`dropstat-network-deploy`](../dropstat-network-deploy), re-aplicá y
re-habilitá las rutas en el admin.
