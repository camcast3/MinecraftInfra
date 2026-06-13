# C2E2 packwiz manifest

This directory is the **source of truth** for the Craft to Exile 2 server's
mod set. Both the production server (Proxmox VM via Portainer GitOps) and
the published client zip (PR 2's admin-side build) are materialized from
`pack.toml` + `index.toml` + `mods/*.pw.toml`.

The Velocity proxy plugin manifest lives in a sibling
`packwiz/velocity/` directory (added in PR 3).

## How the server consumes this

`docker/proxmox/docker-compose.yml` sets `PACKWIZ_URL` on the
`craft-to-exile-2` service to a raw-GitHub URL **pinned to a specific
commit SHA** (not `main`):

```
PACKWIZ_URL: https://raw.githubusercontent.com/camcast3/MinecraftInfra/${PACKWIZ_COMMIT_SHA}/packwiz/pack.toml
```

`${PACKWIZ_COMMIT_SHA}` is read from `docker/proxmox/.env`. itzg's
`minecraft-server` image fetches `pack.toml` at every container start
and runs `packwiz-installer` against it, populating `/data/mods/`,
`/data/config/`, `/data/defaultconfigs/`, etc. Mods flagged
`side = "server"` are installed; `side = "client"` are skipped.

The SHA pin means a merge to `main` that changes a `.pw.toml` does NOT
flip the production server — that only happens when PR 2's publish flow
bumps `PACKWIZ_COMMIT_SHA` (atomic with shipping a new client zip).

See https://docs.itzg.me/docker-minecraft-server/mods-and-plugins/packwiz/
for upstream packwiz support details.

## How to bootstrap / refresh the C2E2 modlist

`pack.toml` currently lists only the **three server-only overlay mods**
(spark, Proxy-Compatible-Forge, minecraft-prometheus-exporter). To fold
in the full Craft to Exile 2 modlist (or to bump to a new upstream C2E2
release), run the admin-side helper:

```powershell
# from the repo root
./infra/azure/scripts/import-curseforge-pack.ps1 -PackZip path\to\Craft+To+Exile+2-<version>.zip
```

The script:

1. Backs up the three overlay `mods/*.pw.toml` files.
2. Runs `packwiz curseforge import <zip>` against this directory
   (which **replaces** `pack.toml` + `index.toml` + `mods/`).
3. Restores the three overlay mods on top of the freshly-imported pack.
4. Runs `packwiz refresh` to regenerate `index.toml`.

Commit the result and open a PR. The new pack only goes live on the
production server when PR 2's publish flow advances `PACKWIZ_COMMIT_SHA`
to the merge commit.

## Manual edits

Adding a single mod (e.g. a hotfix not yet in the upstream C2E2 release):

```powershell
cd packwiz
# Modrinth — preferred (auto-bumped by PR 4's daily workflow)
packwiz modrinth add <slug>
# CurseForge — also auto-bumped
packwiz curseforge install <slug>
# URL — manual bumps only (won't be auto-detected by PR 4)
packwiz url add <name> <url>
packwiz refresh
```

Then mark `side = "server"` in the generated `.pw.toml` if it's a
server-only mod (PCF, spark, prom-exporter, etc.) and refresh again.

## Installing the packwiz CLI

```powershell
go install github.com/packwiz/packwiz@latest
```

The CI workflow added in PR 4 uses the same source. Go is the upstream
toolchain — no third-party binary distribution to trust. Prebuilt
binaries are also available as GitHub Actions artifacts at
https://nightly.link/packwiz/packwiz/workflows/go/main if you'd rather
not install Go.


## Data preservation contract (server side)

`packwiz-installer` writes only to modpack-content paths under `/data/`:
`mods/`, `config/`, `defaultconfigs/`, `resourcepacks/`, `scripts/`,
`kubejs/`, and similar mod-loader directories. It NEVER touches:

- `/data/world/`, `/data/world_nether/`, `/data/world_the_end/`
  — chunk data, level.dat, player .dat files
- `/data/backups/` — managed by the `mc-backup` services in the Proxmox stack
- `/data/logs/`, `/data/crash-reports/`
- `/data/server.properties`, `/data/banned-*.json`, `/data/ops.json`,
  `/data/whitelist.json` — managed by itzg's URL-sync of
  `docker/shared/*.json`

So a `docker compose restart c2e2-local` (or Portainer GitOps redeploy in
production) is *always* safe with respect to world state and player saves
— only the modlist + mod configs are rewritten from the manifest.

## First-deploy / AUTO_CURSEFORGE → packwiz cutover

The legacy `TYPE: AUTO_CURSEFORGE` flow installed mods into `/data/mods/`
*without* per-file tracking. `packwiz-installer` only manages files it
installed, so on the FIRST packwiz-driven start the old AUTO_CURSEFORGE
JARs would linger alongside the freshly installed packwiz JARs, causing
Forge to error on duplicate mod IDs.

One-time cleanup on the Proxmox VM, run BEFORE the first packwiz redeploy
(skip on a fresh stand-up that has never run AUTO_CURSEFORGE):

```sh
# As root on the Proxmox VM. Stop C2E2 via Portainer's UI (Stacks → c2e2 →
# Stop), or shell into the VM and use docker directly:
sudo docker stop mc-c2e2

# Wipe just the modlist — world data lives in /data/minecraft/c2e2/world/*
# and is UNAFFECTED.
sudo rm -rf /data/minecraft/c2e2/mods/*.jar

# Optional but recommended: defaultconfigs/ may contain stale CF entries
# that would override packwiz's. config/ likewise may have CF artefacts.
# These will be re-materialized from packwiz on the next start.
sudo rm -rf /data/minecraft/c2e2/defaultconfigs

# Bring the stack back up via Portainer UI (Start) or wait for the next
# GitOps poll. Watch the c2e2 container logs for "packwiz-installer" lines.
```

Subsequent redeploys are clean — `packwiz-installer` keeps an
on-disk record of what it installed and reconciles `/data/mods/`
against the manifest on every start, so JARs dropped from `mods/*.pw.toml`
are removed automatically.
