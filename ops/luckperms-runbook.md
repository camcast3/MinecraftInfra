# LuckPerms permissions runbook (Craft to Exile 2)

How player ranks and mod permissions work on the C2E2 backend, and how to
manage them reproducibly from the repo.

## The model: two layers, not one

C2E2 runs on **Forge**, and Forge's permission story is different from
Bukkit/Spigot. This is the single most important thing to understand before
touching permissions:

> **LuckPerms on Forge only governs mods that register a named permission node
> through Forge's `PermissionAPI`. It does *not* intercept the integer op-level
> check (`source.hasPermission(int)`) that vanilla commands and the *majority*
> of mods use.**

So permissions are split across two layers:

| Layer | Controls | Source of truth |
|---|---|---|
| **Op level (0–4)** | vanilla commands (`/gamemode`, `/tp`, …) + most mods that gate by op level — e.g. `flan` (`permissionLevel=2`), `lightmanscurrency` (`placementPermissionLevel=2`), command blocks | [`docker/shared/ops.json`](../docker/shared/ops.json) (git-synced into the container) |
| **LuckPerms nodes** | the handful of mods that register `PermissionAPI` nodes (spark, FTB suite, …) + chat prefixes / meta | LuckPerms H2 store, seeded from [`docker/shared/luckperms/permissions-bootstrap.txt`](../docker/shared/luckperms/permissions-bootstrap.txt) |

LuckPerms **does not replace** `ops.json`. `camcast` (level 4) and `Anti_Good`
(level 3) must stay opped there for op-gated commands to work; LuckPerms layers
ranks + node-aware mods on top.

## Group hierarchy

Derived from the current user list (`ops.json` + `whitelist.json`):

| Group | Weight | Members | Op level | LuckPerms grants |
|---|---|---|---|---|
| `owner` | 100 | camcast | 4 (ops.json) | `*` (all nodes) + prefix |
| `admin` | 50 | Anti_Good | 3 (ops.json) | `spark`, `ftbquests.edit` + prefix |
| `default` | 0 | FishMody, DiamondShears, EvOParth, DohWhoopsieDaisy, FoxtheSamurai, trickybat7908 | — | prefix only |

`owner` inherits `admin` inherits `default`.

## Applying / reconciling the bootstrap

The bootstrap file is a list of `rcon-cli` commands (one per line, no leading
slash). Apply it against the running server via RCON (`mc-c2e2:25575`):

```sh
# As root on the Proxmox VM, from a checkout of this repo (or scp the file over):
docker exec -i mc-c2e2 rcon-cli < docker/shared/luckperms/permissions-bootstrap.txt
```

`rcon-cli` inside the `mc-c2e2` container reads `RCON_PASSWORD` / `RCON_PORT`
from its environment automatically — no flags needed.

The commands are **idempotent**: `creategroup` on an existing group is a no-op,
and `parent set` replaces a user's parents, so re-running simply re-asserts the
declared state. Permission data lives at `/data/luckperms/` (H2), inside the
c2e2 volume, so it is captured by the `mc-backup` tarballs and survives
redeploys — you only re-run the bootstrap when you change it.

### Promotions / demotions / new players

1. Edit `permissions-bootstrap.txt` (add/move a `user <name> parent set <group>`
   line; new members also go in `docker/shared/whitelist.json`).
2. Commit + open a PR (per repo convention — no direct commits to `main`).
3. Re-run the bootstrap command above.

## Per-mod permissions

### Mods you can control with LuckPerms (node-aware)

| Mod (in pack) | Node(s) | Default group |
|---|---|---|
| `spark` | `spark` (or granular `spark.profiler`, `spark.heapdump`) | admin+ |
| `ftb-quests-forge` | `ftbquests.edit` (quest editor) | admin+ |
| `ftb-teams-forge` | FTB Library `PermissionAPI` nodes (party admin) | admin+ |
| `ftb-library-forge` | provides the FTB permission bridge other FTB mods use | — |

Everything else in the pack (flan claims, Lightman's Currency admin,
chunk-loaders, starter-kit, global-gamerules, vanilla commands, command blocks)
is **op-level gated** — set it in that mod's own config and/or via op status,
**not** in LuckPerms.

### Discovering a mod's nodes (don't guess)

LuckPerms can log every permission check a mod makes. This is the authoritative
way to find the exact node for any mod and confirm whether it's node-aware at
all:

```
/lp verbose on <player>      # e.g. /lp verbose on Anti_Good
# → have that player run the mod's command / use the feature
/lp verbose off
/lp verbose paste            # uploads a link listing every node checked + result
```

- If a node appears, the mod is node-aware → add
  `group admin permission set <node> true` to the bootstrap.
- If **nothing** appears for the action, that mod is op-gated → control it via
  op level instead (it cannot be managed by LuckPerms on Forge).

## Chat prefixes caveat

The bootstrap sets `meta setprefix` on each group, but prefixes only *render* in
chat if a chat mod reads LuckPerms meta. This pack ships `chat-plus` and
`ftb-placeholders` — verify the prefix actually shows before relying on it;
otherwise the prefix is stored but invisible, which is harmless.

## Why a command bootstrap instead of YAML storage

LuckPerms can also store its data as editable YAML files (`storage-method =
"yaml"` in [`packwiz/config/luckperms.conf`](../packwiz/config/luckperms.conf)),
which could be committed into packwiz for full GitOps. We deliberately use H2 +
this command bootstrap instead because:

- Ranks change rarely, so an explicit, re-runnable command list is simpler to
  review than diffing generated YAML.
- It avoids packwiz re-syncing (and potentially clobbering) live permission data
  on every redeploy.

If the group structure ever grows complex enough to warrant it, switch
`storage-method` to `yaml` and commit `luckperms/groups/*.yml` +
`luckperms/users/*.yml` under packwiz instead.
