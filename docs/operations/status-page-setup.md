# Admin status dashboard — one-time setup runbook

The **admin** status dashboard at https://admin-status.negativezone.cc/ is
served by the `docker/azure/status/docker-compose.yml` stack on the Azure
VM: **cloudflared → traefik → uptime-kuma**, with **fail2ban** as an
active-response sidecar that bans IPs at Cloudflare's edge via the CF API.
Access is gated by **Cloudflare Access** (GitHub OAuth + email allow-list)
on top of CF Tunnel, so only authorized operators ever see the dashboard.

> **The public-facing** status URL — `https://status.negativezone.cc/` —
> is **not** served by this stack. It's hosted by an external SaaS monitor
> so it survives an Azure VM outage. See
> [`docs/operations/external-status-monitor.md`](./external-status-monitor.md)
> for that side of the world. This runbook is admin-only.

Most of the wiring is fully repo-managed and deploys automatically through
`.github/workflows/deploy-azure.yml`. The bits below are **one-time manual
setup** that has to happen before the first deploy of this stack — primarily
because they create resources in your Cloudflare account, mint credentials,
and seed them into Azure Key Vault.

> **Run this once.** After that, rotating tokens / adding monitors / pausing
> the stack all use the same `az vm run-command` deploy flow as the proxy
> stack — no second manual round.

## Prerequisites

- You're an admin of the `negativezone.cc` zone in Cloudflare (or someone
  who is can do steps 1-4 on your behalf and DM you the four resulting
  values).
- You have `az keyvault secret set` access on `kv-minecraft-prod`.
- The proxy stack is already deployed and `mc.negativezone.cc:25565` works
  publicly (Kuma probes that endpoint).

## 1. Create the Cloudflare Tunnel

Cloudflare dashboard → **Zero Trust** → **Networks** → **Tunnels** → **+ Create a tunnel**

1. Connector type: **Cloudflared**.
2. Tunnel name: `tunnel-status-page` (any name works; this is the operator label).
3. **Save tunnel** → Cloudflare shows you the install instructions. Skip
   them — we're going to deploy via docker-compose, not the suggested
   install script. What we need from this page is the **token** shown in
   the "Install and run a connector" command. It's the long base64 string
   right after `--token`. **Copy it.** This is what goes into KV as
   `cloudflare-tunnel-token`.
4. Click **Next**. On the "Public hostnames" step:
   - Subdomain: `admin-status`
   - Domain: `negativezone.cc`
   - Path: *(leave empty)*
   - Service type: `HTTP`
   - URL: `traefik:80`
5. **Save**. Cloudflare auto-creates the DNS record
   (`admin-status.negativezone.cc` CNAME to `<tunnel-id>.cfargotunnel.com`)
   — no manual DNS step needed.

## 2. Find your Cloudflare Account ID

Cloudflare dashboard → any domain → **Overview** (right sidebar) → **Account ID**.

32-char hex string. **Copy it.** Goes into KV as `cloudflare-account-id`.

## 3. Create a scoped Cloudflare API token

Cloudflare dashboard → **My Profile** → **API Tokens** → **Create Token** →
**Create Custom Token**.

| Setting | Value |
|---|---|
| Token name | `fail2ban-status-page-blocklist` |
| Permissions | `Account` → `Account Filter Lists` → `Edit` |
| Permissions (2nd row) | `Zone` → `Zone` → `Read` *(required for token validation)* |
| Account Resources | `Include` → *your-account* |
| Zone Resources | `Include` → `Specific zone` → `negativezone.cc` |
| Client IP Address Filtering | *(leave empty)* |
| TTL | *(leave empty — manual rotation only)* |

**Create Token** → copy the value (only shown once). Goes into KV as
`cloudflare-api-token`.

## 4. Create the blocklist + firewall rule

### 4a. Create the IP list

Cloudflare dashboard → **Manage Account** → **Configurations** → **Lists** →
**Create new list**.

| Setting | Value |
|---|---|
| Name | `status_page_fail2ban_blocklist` |
| Description | `IPs banned by fail2ban on the Azure VM (admin-status.negativezone.cc)` |
| Content type | `IP` |

**Create**. After creation, the list detail page shows a **List ID** at the
top right (URL too: `.../lists/<list_id>`). **Copy it.** Goes into KV as
`cloudflare-list-id`.

### 4b. Create the firewall rule that USES the list

Cloudflare dashboard → **negativezone.cc zone** → **Security** → **WAF** →
**Custom rules** → **Create rule**.

| Setting | Value |
|---|---|
| Rule name | `Block status_page_fail2ban_blocklist` |
| When incoming requests match… | Expression Editor: `(ip.src in $status_page_fail2ban_blocklist)` |
| Then take action… | `Block` |
| Place at… | First |

**Deploy**. The rule fires for any zone request whose source IP is in the
list — meaning fail2ban-banned IPs are blocked at CF before the request
even reaches the tunnel.

## 5. Push tokens + IDs to Azure Key Vault

From a workstation logged in via `az login` (with secrets/officer or
secrets/set permission on `kv-minecraft-prod`):

```sh
az keyvault secret set --vault-name kv-minecraft-prod --name cloudflare-tunnel-token --value '<paste from step 1>'
az keyvault secret set --vault-name kv-minecraft-prod --name cloudflare-api-token    --value '<paste from step 3>'
az keyvault secret set --vault-name kv-minecraft-prod --name cloudflare-account-id   --value '<paste from step 2>'
az keyvault secret set --vault-name kv-minecraft-prod --name cloudflare-list-id      --value '<paste from step 4a>'
```

Quote everything with single quotes so shell expansion doesn't mangle tokens
that contain `$`, `!`, etc.

## 6. First deploy

Trigger the `Deploy Azure VM & Stack` workflow manually
(GitHub → Actions → that workflow → Run workflow → `main`) — or push any
change to `docker/azure/status/**`.

The workflow runs `refresh-env.sh` which writes the four CF secrets to
`/opt/minecraft/secrets/cloudflare_*` on the VM, then runs
`docker compose -f docker/azure/status/docker-compose.yml up -d` to start
the new stack alongside the existing proxy stack.

If you haven't done steps 1-5 yet, `refresh-env.sh` logs a warning
("Cloudflare status-page secrets missing from KV…") and the status-stack
deploy step is **skipped** — the proxy stack deploys normally. Re-running
the workflow after the secrets are in KV picks them up.

## 7. Bootstrap Uptime Kuma

Visit https://admin-status.negativezone.cc/ from a trusted network. First
visit of a fresh deploy shows the **Setup** screen:

1. **Create the admin account.** Use a long random password and store it in
   a password manager. Do this *before* anyone else visits the URL — the
   wizard is open until the admin account exists.
2. After login, go to **Settings → General**:
   - Set **Time zone** to match the host (`America/Los_Angeles`).
   - Set **Primary base URL** to `https://admin-status.negativezone.cc`.
3. **Add the Minecraft monitor.** Dashboard → **+ Add New Monitor**:

   | Setting | Value |
   |---|---|
   | Monitor Type | `Minecraft Server` |
   | Friendly Name | `Craft to Exile 2 (mc.negativezone.cc)` |
   | Hostname | `mc.negativezone.cc` |
   | Port | `25565` |
   | Heartbeat Interval | `60` |
   | Retries | `3` |

   Kuma uses the Minecraft SLP protocol, so "Up" means a real Velocity
   handshake succeeded — a half-broken state (port open, Velocity crashed)
   correctly reports Down.

4. **Create an internal Status Page** (operator dashboard view — not the
   public page; that lives in Better Stack, see
   [`external-status-monitor.md`](./external-status-monitor.md)). Sidebar →
   **Status Pages** → **+ New Status Page**:

   | Setting | Value |
   |---|---|
   | Slug | `/` (root — so the page is at `https://admin-status.negativezone.cc/` directly) |
   | Title | `Negative Zone — Admin Dashboard` |
   | Add Group → Add Monitor | the monitor from step 3 |
   | Custom CSS | *(optional)* |

   **Save**. Kuma's own slug-level page is technically reachable without
   Kuma auth — that's fine here because **Cloudflare Access** (next step)
   gates the entire hostname at the edge before any request reaches Kuma.

## 8. Cloudflare Access — admin authentication

Kuma's built-in admin login (the password from step 7.1) is good, but
stacking Cloudflare Access in front gives us:

- **GitHub OAuth** — log in with the same identity used to push to this
  repo; no separate password to forget or rotate.
- **Zone-level enforcement** — Access blocks unauthorized requests at
  Cloudflare's edge, so brute-force probes never reach Kuma or even
  cloudflared. Big complement to the fail2ban+blocklist defense.
- **Audit logs** — every successful and failed login attempt is recorded
  in CF Zero Trust → Logs → Access, viewable for 6 months on the free plan.
- **Free** — Cloudflare Access free plan covers up to 50 seats. We need 1-3.

### 8a. Register a GitHub OAuth app

GitHub → **Settings** → **Developer settings** → **OAuth Apps** → **New OAuth App**.

| Setting | Value |
|---|---|
| Application name | `negativezone-cf-access` |
| Homepage URL | `https://admin-status.negativezone.cc` |
| Authorization callback URL | `https://<your-team>.cloudflareaccess.com/cdn-cgi/access/callback` |

The `<your-team>` slug is the Cloudflare Zero Trust team subdomain — visible
at CF Zero Trust → Settings → Custom Pages → top of the page, or in the
URL bar when you're in Zero Trust. **Register application** → on the next
page, **Generate a new client secret** and copy both the **Client ID** and
**Client Secret**.

### 8b. Add GitHub as a CF Access login method

CF Zero Trust dashboard → **Settings** → **Authentication** → **Login methods**
→ **Add new** → **GitHub**.

| Setting | Value |
|---|---|
| Name | `GitHub` |
| App ID | *(paste GitHub Client ID from 8a)* |
| Client secret | *(paste GitHub Client Secret from 8a)* |

**Save** → use the **Test** button to verify Cloudflare can complete a
GitHub OAuth round-trip with the credentials.

### 8c. Add the Access application

CF Zero Trust → **Access** → **Applications** → **Add an application** →
**Self-hosted**.

| Setting | Value |
|---|---|
| Application name | `admin-status (Uptime Kuma)` |
| Session duration | `24 hours` *(re-login once a day; tune as needed)* |
| Application domain | Subdomain: `admin-status`, Domain: `negativezone.cc`, Path: *(empty)* |
| Identity providers | check **GitHub** (and optionally **One-time PIN** as fallback) |
| App Launcher | *(optional — adds it to your CF Apps grid)* |

**Next**. Add an access policy:

| Setting | Value |
|---|---|
| Policy name | `Allow operator GitHub identities` |
| Action | `Allow` |
| Session duration | *(use application default)* |
| Include rule 1 | `Emails` → comma-separated list of operator emails (matches the email returned by GitHub OAuth — must be a verified, public-or-private-but-visible email on the GitHub account) |
| Require rule | `Login Methods` → `GitHub` |

**Next** → **Add application**. Access is enforced immediately on the
hostname. No restart of cloudflared / traefik / kuma needed.

### 8d. Test

From an incognito window (no existing CF Access session):

1. Visit `https://admin-status.negativezone.cc/`.
2. Expect to be redirected to a Cloudflare Access login chooser with
   **GitHub** as a button.
3. Click GitHub → authorize the OAuth app if it's the first time → CF
   matches your verified GitHub email against the allow-list policy.
4. On success: redirected back to Kuma, which then asks for *its* admin
   password (defense in depth — Access proves you're in the allow-list,
   Kuma still wants its own password before serving the dashboard).
5. On failure (email not in allow-list, or GitHub auth denied): CF shows
   a `You don't have access to this application` page; Kuma is never
   contacted.

If something is misconfigured, CF Zero Trust → **Logs** → **Access** shows
exactly which rule denied the request and why.

## Operations runbooks

### Rotate the Cloudflare Tunnel token

1. CF dashboard → Zero Trust → Networks → Tunnels → the tunnel →
   **Refresh** the connector token (this generates a new one and invalidates
   the old).
2. `az keyvault secret set --vault-name kv-minecraft-prod --name cloudflare-tunnel-token --value '<new token>'`
3. Trigger the deploy workflow (manual dispatch is fine). `refresh-env.sh`
   re-writes `/opt/minecraft/secrets/cloudflare_tunnel_token`; the
   cloudflared container picks up the new file on next start.
4. `az vm run-command invoke -g rg-minecraft-prod -n vm-minecraft-prod \
       --command-id RunShellScript \
       --scripts 'docker compose -f /opt/minecraft/docker/azure/status/docker-compose.yml up -d --force-recreate cloudflared'`

### Rotate the Cloudflare API token

Same flow as above, substituting `cloudflare-api-token` and
`--force-recreate fail2ban`. The token is read fresh on every fail2ban
action invocation (the helper script `read_secret()`s on each call), so the
restart is mainly to clear any in-memory caches.

### Unban an IP manually

Cloudflare dashboard → **Manage Account** → **Configurations** → **Lists**
→ `status_page_fail2ban_blocklist` → find the row → **Delete**.

The block stops applying immediately. Fail2ban's local DB still has the IP
recorded as banned (until the configured `bantime` expires), so the same
client could be re-banned by a fresh offense — that's fine.

To also clear the local ban so the IP gets a fresh start:

```sh
az vm run-command invoke -g rg-minecraft-prod -n vm-minecraft-prod \
  --command-id RunShellScript \
  --scripts 'docker compose -f /opt/minecraft/docker/azure/status/docker-compose.yml exec fail2ban fail2ban-client unban <ip>'
```

This calls the cloudflare-api action's `actionunban` (idempotent — a no-op
if the IP isn't in the CF list anymore) AND clears the local fail2ban DB
entry.

### Stop the admin status stack (without affecting the proxy stack)

```sh
az vm run-command invoke -g rg-minecraft-prod -n vm-minecraft-prod \
  --command-id RunShellScript \
  --scripts 'docker compose -f /opt/minecraft/docker/azure/status/docker-compose.yml down'
```

The proxy stack (`docker/azure/docker-compose.yml`) is unaffected — they're
separate compose projects on separate docker networks. Players keep playing
even while the admin dashboard is down, and the public status page at
`status.negativezone.cc` keeps working too (it's hosted externally — see
[`external-status-monitor.md`](./external-status-monitor.md)).

### Verify after deploy

From a workstation:

```sh
# 1. Admin dashboard reachable (expect a 302 to Cloudflare Access login
#    when unauthenticated — that proves CF Access AND the tunnel/Traefik/Kuma
#    chain are all up). Add `-H "CF-Access-Client-Id: ..."` headers from a
#    service token if you want to bypass the login wall in automation.
curl -sSI https://admin-status.negativezone.cc/ | head

# 2. cloudflared tunnel registered (CF dashboard → Tunnels → should show Healthy)

# 3. Fail2ban active jails
az vm run-command invoke -g rg-minecraft-prod -n vm-minecraft-prod \
  --command-id RunShellScript \
  --scripts 'docker compose -f /opt/minecraft/docker/azure/status/docker-compose.yml exec -T fail2ban fail2ban-client status' \
  --output json | jq -r '.value[0].message'

# 4. Traefik access log writing (proves traefik is serving requests, log
#    rotation pending — see "Out of scope" below)
az vm run-command invoke -g rg-minecraft-prod -n vm-minecraft-prod \
  --command-id RunShellScript \
  --scripts 'tail -n 5 /data/minecraft/traefik/access.log' \
  --output json | jq -r '.value[0].message'
```

## Out of scope (future improvements)

- **Log rotation for `/data/minecraft/traefik/access.log`.** Traefik doesn't
  rotate access logs internally and the file grows unbounded. Low priority
  for a low-traffic status page (typical growth ~MB/month), but should be
  addressed with a `/etc/logrotate.d/` entry that USR1-signals traefik to
  reopen the file. Not blocking the initial rollout.
- **IaC for the Cloudflare-side resources** (tunnel, public hostname,
  firewall rule, IP list). Doable with the Cloudflare Terraform provider;
  not done here because one-time manual setup is faster and lower-stakes
  than introducing a new IaC stack. Tokens still cycle through KV → script
  → secret-file like every other secret in this repo.
- **Notification channels** (Discord/email when Kuma flips a monitor to
  Down). Kuma supports lots of these out of the box; configure via the
  Kuma UI when desired.
- **Auto-sync between a maintenance-mode workflow and Kuma's "Under
  Maintenance" state** — that's Phase 3 from `plan.md`, a separate PR.
