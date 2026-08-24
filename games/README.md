# Games

Game-specific source belongs here. The first migration slice establishes:

| Owner path | Compatibility/live path | Status |
|---|---|---|
| `games/minecraft/client/` | `client/` | compatibility copy; release asset names and URLs unchanged |
| `games/minecraft/c2e2/docker-compose.yml` | `docker/proxmox/docker-compose.yml` | Portainer still uses the old path |
| `games/minecraft/shared/` | `docker/shared/` | old raw GitHub URLs remain supported |
| `games/palworld/docker-compose.yml` | `docker/palworld/docker-compose.yml` | do not repoint before Palworld promotion |
| `games/windrose/` | `docker/windrose/` | do not repoint before Windrose promotion |

The C2E2 packwiz manifest remains at `packwiz/`, and `modpack.yml` remains at the
repository root. Their commit-pinned raw GitHub URLs are released interfaces, so they
will move only after dual publication and client/server soak gates exist.

