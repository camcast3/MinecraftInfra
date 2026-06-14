# External status monitor — one-time setup runbook

The **public-facing** status page at https://status.negativezone.cc/ is
served by **[Better Stack](https://betterstack.com/uptime)** — an external
SaaS uptime monitor — *not* by anything we run on the Azure VM. The page
is hosted on Better Stack's infrastructure and the probes that drive it
originate from their probe network, so the public URL keeps working when
the Azure VM is down, when Cloudflare is down, or both.

The self-hosted Uptime Kuma stack (Phase 2) still exists — it's just the
**admin** dashboard now, at `admin-status.negativezone.cc`, gated behind
Cloudflare Access. See [`status-page-setup.md`](./status-page-setup.md)
for that side.

> **Run this once.** After that, alert-contact rollover / monitor edits /
> custom-domain re-issuance all happen in Better Stack's UI without
> further repo or VM changes. There is nothing to deploy.

## Why this exists

Phase 2's self-hosted Uptime Kuma runs on the same Azure VM as the
Minecraft proxy. If the VM is unreachable (Azure host issue, OS-patch
reboot loop, NSG misconfiguration, disk full, bad cloud-init, etc.),
both the game **and** the self-hosted Kuma go dark simultaneously —
which is exactly when users most want to see a status page.

Phase 4 solves this with a second, fully external layer:

| Layer | Where it lives | Probes from | What it tells you |
|---|---|---|---|
| Public — `status.negativezone.cc` | Better Stack (SaaS) | Better Stack's global probe network | "Is the game reachable from the internet?" Simple up/down + incident history. |
| Admin — `admin-status.negativezone.cc` | Self-hosted Kuma on Azure VM | The VM itself | Multi-monitor dashboard, latency graphs, cert expiry, notifications, future custom probes. Operator-only. |

VM down → public page still works. Better Stack down → admin Kuma still
works. Both down → genuinely catastrophic, and we have bigger problems.

## Why Better Stack (and not UptimeRobot)

The Phase 4 plan originally recommended UptimeRobot, but as of 2026
UptimeRobot moved **custom-domain CNAMEs** for public status pages from
free to paid (Solo+ at $9/mo). Without a CNAME we'd have to give up the
`status.negativezone.cc` URL and ship players to
`stats.uptimerobot.com/<id>`, which is a regression.

**Better Stack** free tier keeps the CNAME on free, plus comes with
shorter check intervals (3 min vs UptimeRobot's 5 min) and the same TCP
port + email/Slack alerts we needed. Single product, well documented,
shares the same "DNS-only at Cloudflare" CNAME pattern.

If Better Stack ever ratchets their free tier the same way UptimeRobot
did, the **Migrating to a different provider** section at the bottom of
this doc walks through the swap — it's basically just one DNS record.

## One-time setup

### 1. Create a Better Stack account

[betterstack.com/uptime](https://betterstack.com/uptime) → **Sign up**.
Free plan, no credit card. Use an email an actual operator monitors —
this is also where the first round of downtime alerts will go.

### 2. Create the TCP port monitor

Better Stack dashboard → **Uptime** → **Monitors** → **Create monitor**.

| Setting | Value |
|---|---|
| Monitor type | `TCP port` |
| URL or IP address | `mc.negativezone.cc` |
| Port | `25565` |
| Monitor name | `Craft to Exile 2 (mc.negativezone.cc:25565)` |
| Check frequency | `3 minutes` *(shortest the free tier allows)* |
| Recovery period | `1` *(seconds the port has to stay up before declaring "recovered")* |
| Confirmation period | `0` *(check from a single region; lower false-positive risk than multi-region for a single-server target)* |
| Maintenance windows | leave default |

**Create monitor**. Within one check interval (~3 min) the monitor flips
to **Up** with a green dot. If it doesn't, the most common causes are:
the VM is genuinely down; the NSG is blocking inbound from Better
Stack's probe IP ranges (it shouldn't — port 25565 is public to the
world); or the hostname doesn't resolve yet.

> Note: this is a raw TCP handshake, not a Minecraft SLP handshake. A
> half-broken state where the port is open but Velocity has crashed
> won't register as Down on the public page. The admin Kuma (Phase 2)
> uses the SLP protocol so it catches that case — which is why we keep
> both layers.

### 3. Create the public status page

Better Stack dashboard → **Status pages** → **Create status page**.

| Setting | Value |
|---|---|
| Status page name | `Negative Zone — Craft to Exile 2` |
| Subdomain | `negativezone` *(this becomes `negativezone.betteruptime.com` — placeholder; the custom domain we set in step 4 supersedes it)* |
| Page visibility | `Public` |
| Add resources → add monitor | the monitor from step 2 |
| Section name | `Minecraft` |

**Create**. The page is now live at `negativezone.betteruptime.com`. We
want it on `status.negativezone.cc` instead — next step.

### 4. Wire up the custom domain

#### 4a. Tell Better Stack about the custom domain

In the status page settings → **Custom domain** → enter
`status.negativezone.cc` → **Save**. Better Stack provisions an SSL
certificate for the hostname (Let's Encrypt under the hood) once the
CNAME from step 4b resolves.

#### 4b. Swap the Cloudflare DNS record

Cloudflare dashboard → `negativezone.cc` zone → **DNS** → **Records**.

The existing `status` record is currently a CNAME to
`<tunnel-id>.cfargotunnel.com` (from the Phase 2 Cloudflare Tunnel
setup). **Edit** it:

| Field | Old value | New value |
|---|---|---|
| Type | `CNAME` | `CNAME` |
| Name | `status` | `status` |
| Target | `<tunnel-id>.cfargotunnel.com` | `statuspage.betteruptime.com` |
| Proxy status | (any) | **DNS only** (gray cloud — NOT orange) |
| TTL | Auto | Auto |

**Save**. DNS-only mode is **required** — Better Stack serves the page
from their own CDN with their own TLS cert; routing it back through
Cloudflare's proxy would break SSL termination (CF would try to
re-terminate against an origin that's already itself a CDN).

> If you ever want to use Cloudflare for DDoS protection on this
> hostname, the right path is a CF Worker that proxies to Better Stack
> on Cloudflare's edge. Out of scope here; the page is static and Better
> Stack's CDN is fine for our traffic.

DNS propagation: typically <60s if your TTL was Auto, up to 72h
worst-case. Better Stack auto-validates the CNAME and issues the SSL
cert within a few minutes after propagation completes.

### 5. Wire up alert contacts

Better Stack dashboard → **Integrations** → **On-call calendar / Notify
people**.

At minimum, add the **email** contact for the account owner. Optional:

- **Discord webhook** — create an incoming webhook in the Discord server
  channel where ops chatter happens, paste the URL into Better Stack's
  Discord integration. Alerts post as embeds with monitor name + status
  change.
- **Slack webhook** — same shape, different chat app.
- **SMS** — paid add-on (~$0.10/SMS). Skip unless the game ever becomes
  business-critical.

In the monitor (step 2) → **Edit** → **Escalation policy** → add the
contacts. Send a test alert from the integration's **Test** button to
make sure end-to-end delivery actually works **before** you'd otherwise
find out at 2am.

### 6. Move the old Cloudflare Tunnel hostname to the admin URL

This step lives in [`status-page-setup.md`](./status-page-setup.md) (the
admin runbook) — specifically the "Create the Cloudflare Tunnel" and
"Cloudflare Access — admin authentication" sections. In short: the
tunnel that used to publish `status.negativezone.cc` now publishes
`admin-status.negativezone.cc`, and Cloudflare Access enforces
GitHub-OAuth-based admin auth on it.

If you've already done Phase 2's setup using the *old* hostname:

1. CF Zero Trust → **Networks** → **Tunnels** → `tunnel-status-page` →
   **Public Hostname** tab → edit the row for `status.negativezone.cc`,
   change the subdomain to `admin-status`. Save.
2. Cloudflare auto-updates the DNS record for `admin-status` and removes
   the one for `status` (so step 4b above is editing a DIFFERENT record
   from what was there originally — the old tunnel record has by now
   been removed). If for any reason the `status` CNAME wasn't removed,
   make sure step 4b targets `statuspage.betteruptime.com` (not the
   tunnel) after the swap.

## Verification

From a workstation, in an incognito window (no CF Access session, no
cached DNS):

```sh
# 1. status.negativezone.cc resolves to a Better Stack edge (NOT cfargotunnel.com).
dig +short status.negativezone.cc CNAME
# Expected: statuspage.betteruptime.com.

# 2. The custom domain serves over HTTPS with Better Stack's cert.
curl -sSI https://status.negativezone.cc/ | grep -iE '^(HTTP|server|x-)'
# Expected: HTTP/2 200, server header looks like Better Stack / Cloudflare
# at their edge — NOT cloudflared.

# 3. The page renders the Better Stack status UI with the Craft to Exile 2
#    monitor showing Up.
#    (Visual check — open https://status.negativezone.cc/ in a browser.)
```

Then **test the alert path** end-to-end. Pick one:

- **Pause the monitor** (Better Stack UI → monitor → Pause) — clean way
  to fire a *manual* incident notification without actually breaking
  anything. Resume immediately after the alert lands.
- **Stop Velocity briefly** — more realistic. From a workstation:
  ```sh
  # Stop
  az vm run-command invoke -g rg-minecraft-prod -n vm-minecraft-prod \
    --command-id RunShellScript \
    --scripts 'docker compose -f /opt/minecraft/docker/azure/docker-compose.yml stop velocity'
  # Wait ~5 min for Better Stack to register the outage and alert.
  # Then restart:
  az vm run-command invoke -g rg-minecraft-prod -n vm-minecraft-prod \
    --command-id RunShellScript \
    --scripts 'docker compose -f /opt/minecraft/docker/azure/docker-compose.yml start velocity'
  ```
  Do this **inside a 6-minute window** (3-min check + ~1 confirmation +
  buffer) so the test outage is brief and there's no cron / other
  automation that might react to the proxy being down.

Both methods should:
- Email the alert contact within one check interval after the down
  state is confirmed.
- Show an incident on https://status.negativezone.cc/.
- Auto-resolve and notify on recovery once the monitor goes Up again.

## Operating notes

- **5-min-or-shorter outages may not register on the public page.**
  Free-tier check interval is 3 min, so an outage shorter than ~3 min
  will likely fall between probes. The admin Kuma (60s heartbeat,
  Phase 2) still catches them. Most outages players would actually
  notice (≥1 min of "can't connect") last long enough for the public
  page to catch.
- **Probes originate from Better Stack's global probe network, not
  Cloudflare.** They hit `mc.negativezone.cc:25565` directly. That's
  fine — port 25565 is public anyway (Velocity needs to accept player
  connections from the internet).
- **The public page is served by Better Stack's CDN.** It survives
  Azure VM outages **and** Cloudflare outages. It does NOT survive a
  Better Stack outage — but their published SLA is 99.95% and they're
  not running on the same providers we are, so correlated downtime is
  very unlikely.
- **No secrets in this repo.** Unlike the Phase 2 stack, this monitor
  has nothing in Azure Key Vault, nothing in the deploy workflow,
  nothing in compose. Everything lives in Better Stack's UI. If we ever
  want to manage it as IaC, Better Stack ships a [Terraform
  provider](https://registry.terraform.io/providers/BetterStackHQ/better-uptime/latest/docs);
  out of scope for now.

### Free-tier limits to be aware of

| Limit | Free tier | Our usage |
|---|---|---|
| Monitors | 10 | 1 (room for ~9 more if we ever want to monitor BattleMetrics, web panels, etc.) |
| Check interval (min) | 3 min | 3 min |
| Public status pages | 1 | 1 |
| Custom domains on the status page | 1 | 1 (`status.negativezone.cc`) |
| Email alert contacts | unlimited | 1 |
| Slack / Discord webhooks | included | 0-1 |
| Incident history retention | 90 days | fine |
| SMS / phone-call alerts | not included | not needed |

If we ever hit a limit, the **Pro Plan** starts at ~$25/mo (50
monitors, 30-sec interval, SMS, multiple status pages). Almost
certainly never necessary for this server.

## Migrating to a different provider

If Better Stack changes their free tier the same way UptimeRobot did:

1. Pick a new SaaS that offers free TCP port monitoring + free
   custom-domain CNAME on a public status page. Candidates as of 2026:
   StatusGator, Hyperping, Freshping. Re-verify free-tier coverage on
   their pricing page **before** signing up — this market churns.
2. Set up the equivalent monitor + page + custom domain in the new
   provider; they'll give you a new CNAME target.
3. In Cloudflare DNS, edit the `status.negativezone.cc` CNAME to point
   at the new target. Keep **DNS-only** mode.
4. Update step 4b above with the new CNAME target value.
5. Cancel the Better Stack monitor (or downgrade to keep it as a
   redundant probe — the free tier lets you keep monitors that aren't
   on the public page).

Total elapsed time: ~30 min, mostly DNS propagation. No code or VM
changes.

## Cost

**$0/month additional.** Better Stack free + Cloudflare DNS (free for
zones we already own) + existing Azure VM + existing Cloudflare zone.

What we *would* pay for if we ever wanted something we don't currently
have:

| Feature | Cost (rough, 2026) |
|---|---|
| 30-second check interval | ~$25/mo (Better Stack Pro) |
| Multiple custom-domain status pages | ~$25/mo |
| Phone/SMS alerts | $0.05–$0.10 per alert on top of base plan |
| Multi-region probing (more confidence on regional outages) | included on Pro |

None of these are anywhere close to justified for a private Minecraft
server.

## See also

- [`status-page-setup.md`](./status-page-setup.md) — admin dashboard
  (Phase 2 stack: cloudflared + traefik + Kuma + fail2ban behind CF Access).
