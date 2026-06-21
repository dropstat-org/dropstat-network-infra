> 🌐 [Español](README.es.md)

# dropstat-network-infra

Reusable **Terraform modules** for Dropstat's shared network infrastructure: the
self-hosted **Headscale** control plane and the highly-available **Tailscale subnet
router** that together provide private, identity-based access to every AWS account
through the Transit Gateway.

This repository is a **module library only** — it contains no live state and is never
applied directly. It is consumed by [`dropstat-network-deploy`](../dropstat-network-deploy)
(the Terragrunt deploy layer) via `github.com/dropstat-org/dropstat-network-infra//_modules/...?ref=main`.

---

## 1. Overview and purpose

Dropstat runs a multi-account AWS organization wired together by a central Transit
Gateway in the **network account** (`027053844689`). Humans and CI need private access
to resources in those accounts (Aurora, ECS, internal ALBs) without exposing anything to
the public internet and without a heavyweight corporate VPN appliance.

The solution is a **self-hosted Tailscale stack**:

- **Headscale** — an open-source, self-hosted implementation of the Tailscale control
  plane. It runs on a single EC2 instance in the egress VPC and authenticates users via
  Google OIDC. No dependency on the Tailscale SaaS.
- **Tailscale subnet router** — an Auto Scaling Group (2 instances, one per AZ) that
  advertises `10.0.0.0/8` into the tailnet. Any device joined to the tailnet can reach
  every workload account through the Transit Gateway, with Tailscale handling automatic
  failover between the two router instances.

Both modules are designed for **zero inbound SSH**: management is exclusively through
AWS SSM Session Manager, and secrets are pulled from AWS Secrets Manager at boot.

The modules use the shared discovery module
`github.com/dropstat-org/tm-aws-account-data` to locate the egress VPC and the correctly
tagged subnets at apply time, so they require no hardcoded subnet IDs.

---

## 2. Architecture diagram

```
                          Internet
                             │
                             ▼
        ┌────────────────────────────────────────────────────────────┐
        │           Network account  (dropstat-network, 027053844689) │
        │                                                              │
        │   Egress VPC  10.0.0.0/24                                    │
        │   ┌───────────────────────────┐   ┌──────────────────────┐  │
        │   │ public subnet (10.0.0.0/26)│  │ network/tgw subnets   │  │
        │   │                           │   │ (one per AZ)          │  │
        │   │  ┌─────────────────────┐  │   │  ┌────────────────┐   │  │
        │   │  │ headscale-server    │  │   │  │ tailscale-router│  │  │
        │   │  │ EC2 t3.small        │  │   │  │ ASG  2 × t3.nano│  │  │
        │   │  │ Elastic IP (stable) │  │   │  │ (2a + 2b)       │  │  │
        │   │  │ Caddy :443→:8080    │  │   │  │ advertises      │  │  │
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
          dev (10.1.0.0/18)   shared-svcs(10.0.1.0/24)  staging (future)  prod (future)
          Aurora / ECS / Redis   ECR / runners / SSO

   Laptop ──HTTPS──► Headscale Elastic IP   (login via Google OIDC)
   Laptop ──WireGuard──► tailnet ──► subnet router ──► TGW ──► any account
```

---

## 3. Repository structure

```
dropstat-network-infra/
├── README.md                      ← this file (English)
├── README.es.md                   ← Spanish version
└── _modules/
    ├── headscale-server/          ← self-hosted Tailscale control plane
    │   ├── main.tf                ← EIP, EC2, SG, IAM, Secrets Manager, user_data
    │   ├── variables.tf           ← name, instance_type, tags
    │   └── outputs.tf             ← public_ip, server_url, instance_id, oidc_secret_*
    └── tailscale-router/          ← HA subnet router (ASG)
        ├── main.tf                ← launch template, ASG, SG, IAM, Secrets Manager
        ├── variables.tf           ← name, instance_type, advertise_routes, headscale_url, tags
        └── outputs.tf             ← asg_name, secret_arn, secret_name, launch_template_id
```

---

## 4. Managed resources

### Module `headscale-server`

| Resource | Name / value | Notes |
|----------|--------------|-------|
| `aws_eip.headscale` | `${name}-headscale` | Stable public IP for clients |
| `aws_eip_association.headscale` | — | Binds EIP to the EC2 instance |
| `module.ec2` (`terraform-aws-modules/ec2-instance ~> 5.0`) | `${name}-headscale-server` | `t3.small` default, Amazon Linux 2023, public subnet |
| `aws_secretsmanager_secret.oidc` | `${name}/headscale/oidc` | Google OIDC `client_id` / `client_secret` (loaded manually) |
| `module.sg` (`terraform-aws-modules/security-group ~> 5.0`) | `${name}-headscale-server` | Inbound 443/tcp (HTTPS) + 3478/udp (STUN); all egress |
| `aws_iam_role.headscale` | `${name}-headscale-server` | SSM core + read OIDC secret |
| `aws_iam_instance_profile.headscale` | `${name}-headscale-server` | — |

**Software stack (provisioned via user_data):** Headscale 0.23.0 (control plane on
`:8080`), Caddy (HTTPS reverse proxy `:443 → :8080`, internal TLS), SQLite (embedded DB,
fine for < 50 users). Tailnet IP range `100.64.0.0/10`. MagicDNS base domain
`vpn.dropstat.internal`. A default `vpn` user is created on first boot.

### Module `tailscale-router`

| Resource | Name / value | Notes |
|----------|--------------|-------|
| `aws_secretsmanager_secret.authkey` | `${name}/tailscale/auth-key` | Reusable Tailscale auth key, no expiry (loaded manually) |
| `aws_launch_template.tailscale` | `${name}-tailscale-router-` | Amazon Linux 2023, no public IP, no key pair |
| `module.asg` (`terraform-aws-modules/autoscaling ~> 8.0`) | `${name}-tailscale-router` | `min=max=desired=2`, one per AZ, EC2 health check, rolling instance refresh |
| `module.sg` (`terraform-aws-modules/security-group ~> 5.0`) | `${name}-tailscale-router` | **Outbound only**: 41641/udp (WireGuard), 443/tcp (control plane), all to `10.0.0.0/8` (forwarding) |
| `aws_iam_role.tailscale` | `${name}-tailscale-router` | SSM core + read auth-key secret |
| `aws_iam_instance_profile.tailscale` | `${name}-tailscale-router` | — |

**Software stack (provisioned via user_data):** enables IPv4/IPv6 forwarding (required for
a subnet router), installs the Tailscale client, fetches the auth key from Secrets Manager,
then runs `tailscale up --login-server=<headscale_url> --advertise-routes=10.0.0.0/8
--accept-dns=false`. Hostname is `${name}-router-<az>`.

---

## 5. Transit Gateway attachment process for new accounts

The TGW itself and its attachments are managed in **platform-infra**, not here. These
network modules consume the TGW only indirectly: the subnet router advertises `10.0.0.0/8`
so that **once an account's VPC is attached to the TGW, it is automatically reachable over
the VPN** — no change to these modules is required.

To add a new account to the network (summary; full process in
[`dropstat-network-deploy`](../dropstat-network-deploy) and platform-infra):

1. Create the account's VPC with a non-overlapping `10.x.0.0/18` CIDR (platform-infra
   `workloads/<env>/vpc/`). The VPC module creates a TGW attachment in
   `pendingAcceptance`.
2. The TGW module in platform-infra (`network/transit-gateway/`) auto-discovers and
   accepts the attachment, then associates it with the correct tier route table.
3. Because the router already advertises `10.0.0.0/8`, the new account's `10.x.x.x` range
   is immediately reachable from any VPN client — **no apply needed in this repo**.

> If the router's advertised range ever needs to change (e.g. to a wider or narrower
> supernet), edit `advertise_routes` in `dropstat-network-deploy`, re-apply, and re-enable
> the route in the Headscale/Tailscale admin.

---

## 6. Headscale / Tailscale VPN setup

### One-time control-plane bring-up

1. **Apply** `headscale-server` (via `dropstat-network-deploy`). This creates the EIP, the
   instance, and the empty OIDC secret.
2. **Load the Google OIDC credentials** into Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id dropstat/headscale/oidc \
     --secret-string '{"client_id":"xxx.apps.googleusercontent.com","client_secret":"yyy"}'
   ```
   The Google OAuth client must allow the redirect URI
   `https://<elastic-ip>/oidc/callback` and be restricted to the `dropstat.com` domain
   (`allowed_domains` in the Headscale config).
3. Headscale reads the secret on next boot (`user_data_replace_on_change = true`), so
   re-apply or replace the instance after loading the secret.

### Bringing the subnet router online

1. **Apply** `tailscale-router`. This creates the ASG and the empty auth-key secret.
2. **Generate a reusable pre-auth key** on the Headscale server (over SSM) and store it:
   ```bash
   aws ssm start-session --target <headscale-instance-id>
   # on the server:
   headscale users create vpn                      # if not already created
   headscale --user vpn preauthkeys create --reusable --expiration 87600h
   ```
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id dropstat/tailscale/auth-key \
     --secret-string "<the-reusable-key>"
   ```
3. Trigger an ASG instance refresh (or terminate the instances) so the routers register
   with the new key.
4. **Approve the advertised routes** on the Headscale server:
   ```bash
   headscale nodes list                            # find the router node IDs
   headscale routes list
   headscale routes enable -r <route-id>           # enable 10.0.0.0/8 for each router
   ```

### Onboarding an end user

```bash
# on the Headscale server (over SSM)
headscale users create alice@dropstat.com
```
The user then runs `tailscale up --login-server=https://<elastic-ip>` on their laptop and
authenticates via Google. After joining, connecting with `--accept-routes` makes the full
`10.0.0.0/8` reachable. Verified path: MySQL Workbench from a VPN-connected Windows client
to `dropstat-dev.cluster-...rds.amazonaws.com:3306`.

> Future: point Headscale `dns_config.nameservers` at the VPC private resolver so clients
> resolve internal hostnames (RDS, ECS) directly.

---

## 7. Subnet tagging conventions (critical for tm-aws-account-data)

Neither module hardcodes subnet IDs. Instead they call the shared discovery module:

```hcl
module "account" {
  source = "git::https://github.com/dropstat-org/tm-aws-account-data.git?ref=master"
}
```

and select subnets by their **logical category**:

| Module | Selector | Where the instance lands |
|--------|----------|--------------------------|
| `headscale-server` | `module.account.subnets.publics` | A **public** subnet (needs a public IP for clients) |
| `tailscale-router` | `module.account.subnets.networks` | The **network / tgw-attachment** subnets, one per AZ for HA |

For `tm-aws-account-data` to classify these subnets correctly, the VPC's subnets **must be
tagged** when created in platform-infra. The egress VPC (`_modules/network-hub`) tags them:

| Subnet purpose | Tag set in platform-infra | Discovered as |
|----------------|---------------------------|---------------|
| Public (NAT + ALBs) | `subnet-type = public` | `subnets.publics` |
| TGW attachment ENIs | `subnet-type = tgw-attachment` | `subnets.networks` |

Workload VPCs (`_modules/workload-vpc`) use the parallel tags `subnet-type =
workload | data | secu`. **If these tags are missing or wrong, discovery returns empty
lists and the modules fail at plan/apply time.** This tagging convention is the contract
between the network modules here and the VPCs defined in platform-infra.

---

## 8. CI/CD pipeline

This repository is a **module library** and has no pipeline of its own — there is nothing
to apply. Modules are versioned by Git ref (`?ref=main`) and validated implicitly when the
consuming repo ([`dropstat-network-deploy`](../dropstat-network-deploy)) runs `terragrunt
plan`/`apply` through the org-standard reusable workflow
(`dropstat-org/gha-actions-core-lib/.github/workflows/actions-core-lib.yml@main`).

Changes here take effect when the deploy repo pins/refreshes the ref and re-applies.

---

## 9. How to add a new account to the network

From the perspective of these modules, **nothing changes** — the router advertises the
whole `10.0.0.0/8` supernet, so a newly attached account is reachable automatically. The
end-to-end checklist (spanning platform-infra and the deploy repo):

1. **platform-infra** — add the account (`common_vars.yaml` → `new_accounts`, `cidrs`,
   `workloads.<env>.tier`) and apply `management/organizations`, then `workloads/<env>/vpc`.
2. **platform-infra** — the TGW module accepts the attachment and associates it with the
   tier route table (auto-discovery). Ensure the new VPC's subnets carry the
   `subnet-type` tags (see §7).
3. **No action in this repo.** The subnet router already covers `10.x.x.x` via the
   advertised `10.0.0.0/8` route.
4. **Optional VPN policy** — to scope which users/tags may reach the new account, update
   the Tailscale/Headscale ACLs (managed operationally on the Headscale server).

If you ever split the advertised supernet into per-environment routes, change
`advertise_routes` in [`dropstat-network-deploy`](../dropstat-network-deploy), re-apply,
and re-enable the routes in the admin.
