# MinecraftInfra Copilot Instructions

> **`old/` is archived legacy content. Do not reference or modify anything in `old/` or `admin_compose.yml`.**

## Architecture

Two-node Minecraft network connected by TailScale:

- **Azure VM (Debian 13)** — public entry point. Runs Velocity proxy (port 25565) + lobby MC server in Docker. GitHub Actions deploys here via `az vm run-command invoke` (Azure control plane, no SSH needed).
- **Home Proxmox VM (Debian 13)** — private. Runs Craft to Exile 2 modded server in Docker, managed by Portainer CE. Updates via Portainer CE GitOps polling (auto-redeploy on git changes to `docker/proxmox/`).
- **TailScale** — mesh VPN for all inter-node traffic (Velocity → C2E2) and all admin SSH. Public SSH (port 22) is blocked on both VMs.

## Repo Layout

```
infra/
  azure/            # Bicep IaC for Azure VM
    main.bicep
    modules/network.bicep
    modules/vm.bicep
    parameters/prod.bicepparam
  proxmox/
    cloud-init.yaml # Debian 13 cloud-init for Proxmox VM
docker/
  shared/           # Whitelist & ops shared by all MC servers
  azure/            # Velocity + Lobby compose stack
  proxmox/          # Craft to Exile 2 compose stack (Portainer-managed)
.github/workflows/
  deploy-azure.yml  # Bicep deploy + az vm run-command push to Azure VM
old/                # ARCHIVED — ignore
```

## Key Conventions

- **Azure IaC:** Bicep only. OIDC / Workload Identity Federation for `az login` — no stored Azure credentials.
- **Azure VM:** `Standard_B4s_v2`, Debian 13, Premium SSD, region `westus`, SSH key auth, NSG blocks port 22 from internet.
- **OS updates:** Both VMs run `unattended-upgrades` (configured in cloud-init) — daily security patches, auto-reboot at off-peak hours.
- **Docker image updates:** Renovate bumps pinned digests in the repo → Azure VM auto-deploys via `deploy-azure.yml` → Proxmox auto-deploys via Portainer GitOps polling.
- **Docker images:** Pinned digests (`image:tag@sha256:...`). Renovate manages bumps.
- **Memory tuning:** `MEMORY: ""` + `JVM_XX_OPTS: "-XX:MaxRAMPercentage=75"` on all MC servers.
- **Online mode:** `ONLINE_MODE: "FALSE"` on all backend servers; Velocity handles Mojang auth at the proxy.
- **Proxmox updates:** Portainer GitOps — Portainer CE polls the GitHub repo on a set interval (e.g., 5 min), detects changes to `docker/proxmox/docker-compose.yml`, and redeploys automatically. No inbound ports or webhooks needed. All env vars set via Portainer stack environment UI only.
- **Secrets:** Never committed. `.env.example` documents all required vars.
- **Player DNS:** `mc.negativezone.cc` — Cloudflare A record (DNS-only, no proxy) pointing to the Azure Public IP. Players connect with this hostname.
- **Access control:** Whitelist-only (no NSG IP filtering). Velocity handles Mojang auth at the proxy; backend servers enforce `whitelist.json` + `ops.json` from `docker/shared/`. Port 25565 is open but only authenticated + whitelisted players can join.
