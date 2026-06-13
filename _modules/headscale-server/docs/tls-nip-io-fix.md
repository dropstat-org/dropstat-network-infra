# Fix: Tailscale client hangs on `tailscale up` (TLS self-signed)

## Síntoma

El subnet router (`tailscale-router`) se queda colgado indefinidamente en:

```
tailscale up --login-server=https://<EIP> --authkey=... --advertise-routes=10.0.0.0/8 ...
```

`ps aux` muestra el proceso `tailscale up` corriendo sin terminar, y
`cloud-final.service` queda en `activating (start)` para siempre — el
resto del `user_data` (incluyendo `systemctl enable tailscaled`) nunca
se ejecuta.

## Causa

Headscale corre detrás de Caddy con:

```caddyfile
:443 {
  reverse_proxy localhost:8080
  tls internal
}
```

`tls internal` le dice a Caddy que emita un certificado **self-signed**
(CA local de Caddy). El cliente Tailscale, al hacer `tailscale up
--login-server=https://<IP>`, valida el certificado TLS del servidor
y no confía en esa CA — la conexión TLS nunca se completa ni falla
explícitamente, simplemente cuelga.

## Fix

Usar **nip.io** (wildcard DNS público, gratis, sin mantenimiento) para
darle a la EIP un hostname resoluble, y dejar que Caddy obtenga un
certificado real de **Let's Encrypt** vía HTTP-01 challenge (puerto 443
ya está abierto al público).

- `nip.io` resuelve `<cualquier-cosa>.<IP>.nip.io` → `<IP>` automáticamente.
  Ej: `52.14.172.37.nip.io` → `52.14.172.37`.

### Cambios

1. **`headscale-server/main.tf`** — `config.yaml`:
   ```yaml
   server_url: https://<EIP>.nip.io
   ```

2. **`headscale-server/main.tf`** — `Caddyfile`:
   ```caddyfile
   <EIP>.nip.io {
     reverse_proxy localhost:8080
   }
   ```
   (sin `tls internal` — Caddy detecta el dominio público y usa Let's
   Encrypt automáticamente vía ACME HTTP-01, dado que `:80` y `:443`
   están abiertos).

3. **`tailscale-router/main.tf`** — flag `--login-server`:
   ```bash
   --login-server="https://<EIP>.nip.io"
   ```

### Consideraciones

- Si la EIP cambia (recreación de `aws_eip.headscale`), el dominio
  `nip.io` cambia automáticamente (se deriva de la IP), pero hay que
  actualizar `tailscale-router` para que apunte al nuevo hostname y
  volver a registrar los routers.
- Let's Encrypt tiene rate limits (50 certs/semana por dominio
  registrado) — no es un problema aquí porque `nip.io` es un dominio
  compartido pero cada subdominio (`<IP>.nip.io`) cuenta aparte.
- Alternativa a futuro: usar un dominio propio bajo `dropstat-np.com`
  (patrón ya usado en otros servicios) + Route53, en vez de `nip.io`.
