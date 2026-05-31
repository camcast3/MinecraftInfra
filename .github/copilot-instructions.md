# MinecraftInfra Copilot Instructions

## Architecture Overview

This repo manages infrastructure and modpack definitions for a self-hosted Minecraft network. The stack has two layers:

1. **Docker Compose** — defines all services. The live compose file is `admin_compose.yml` (Portainer UI); the older full-stack file is `old/docker-compose.yaml`.
2. **packwiz modpacks** — each modpack lives in its own subdirectory (`old/cobblemonextended/`, `old/createexplorextended/`, `old/lobby/`) and is served at runtime by a `ghcr.io/camcast3/packwiz` sidecar container.

### Service topology (from `old/docker-compose.yaml`)

```
Velocity proxy (port 25565) → cobblemonextended
                             → createexplorextended
                             → lobby
```

Each Minecraft server (`itzg/minecraft-server`, Fabric 1.20.1) has a corresponding **packwiz sidecar** that serves `pack.toml` over HTTP. The server pulls mods at startup via `PACKWIZ_URL=http://packwiz-server-<name>:8080/pack.toml`.

Backups run via `itzg/mc-backup` and depend on the server's health check.

### Environment variables

All compose files rely on a `.env` file (not committed) providing:
- `$TZ`, `$PUID`, `$PGID` — timezone and user/group IDs
- `$DOCKERDIR` — base path for bind mounts (e.g., `/dockerdir/appdata/<service>`)

## Modpack Management

Modpacks use [packwiz](https://packwiz.infra.link/) format:
- `pack.toml` — pack metadata (name, version, Fabric/MC versions)
- `index.toml` — SHA-256 manifest of all included files
- `mods/*.pw.toml` — one file per mod (Modrinth or CurseForge metadata)
- `resourcepacks/*.pw.toml` — resource packs
- `datapack/*.pw.toml` — data packs (CobblemonExtended only)
- `modrinth_mods.txt` — source list for bulk-importing mods via packwiz CLI

### Adding mods in bulk

**Windows (PowerShell):**
```powershell
# Run from repo root; packwiz.exe path is hardcoded — adjust as needed
.\old\import_mods.ps1
```

**Linux/macOS:**
```bash
# import_mods.sh <modrinth_mods.txt path> <pack folder> <packwiz binary path>
./old/import_mods.sh modrinth_mods.txt old/cobblemonextended /usr/local/bin/packwiz
```

`modrinth_mods.txt` format: `<slug>/<version-filename>` — one entry per line. The import script splits on `/` and passes each slug + version to `packwiz modrinth add`.

After importing, always run `packwiz refresh` inside the pack directory to regenerate `index.toml` hashes.

## Key Conventions

- **Pinned image digests** — Docker images in compose files use `image:tag@sha256:...` to prevent unexpected updates. Renovate bot manages digest bumps (see `renovate.json`).
- **YAML extension fields** — Compose files use `x-common-keys-core` / `x-common-keys-apps` anchors to avoid repeating `security_opt` and `restart` policy. Core services use `restart: always`; app servers use `restart: unless-stopped`.
- **`ONLINE_MODE: "FALSE"`** — all game servers run in offline mode; authentication is delegated to the Velocity proxy using a shared `forwarding.secret`.
- **Memory tuning** — `MEMORY: ""` disables itzg's built-in heap flags; JVM heap is controlled by `JVM_XX_OPTS: "-XX:MaxRAMPercentage=75"` against the container's memory limit.
- **Renovate rules** — MariaDB/MySQL major+minor bumps are disabled to avoid breaking app stacks. PostgreSQL major bumps are disabled. Standalone DB compose files in `docker-compose/mariadb/` and `docker-compose/postgres/` allow all bump types.
- **`old/` directory** — contains the previous full compose stack and modpack sources. Active deployment is `admin_compose.yml` (Portainer only).
- **`.gitignore`** excludes `setcommands.sh`, `admin_compose.yml`, `*.zip`, and `*.mrpack` — secrets/local scripts and exported modpack archives are never committed.
