---
layout: default
title: Backups
nav_order: 5
---

# Backups & restore
{: .no_toc }

Two player-facing restore mechanisms protect your state, while a third
internal transaction backup protects each setup, update, or migration from a
partial filesystem change.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

---

## The player-facing mechanisms at a glance

|  | **Snapshot files** | **Previous-version backup (`.bak`)** |
|---|---|---|
| **What it is** | Timestamped folders of your personal state files | A full copy of your previous-version install (the whole instance at the *previous* version) |
| **Where** | `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\<yyyyMMdd-HHmmss>\` | `%APPDATA%\PrismLauncher\instances\Craft to Exile 2.bak\` (shows in Prism's grid as a separate instance) |
| **Contains** | Waypoints, world map cache, shaders, resourcepacks, options, recipe bookmarks, plus pack-author-flagged config files (graphics, shaders, HUD, sound prefs, keybinds) | Mods, configs, resourcepacks, libraries — the whole game install at the prior version |
| **Does *not* contain** | Single-player worlds (opt-in), mods, configs not in the pack-author preserve list | — (it's a complete instance) |
| **Created by** | `nz backup` PostExit hook (every Prism close) | `nz setup` when it detects an upgrade (existing instance, different version) |
| **Cadence** | At most once per `NEGATIVEZONE_BACKUP_DAYS` (default 3 days) of play; one is also forced just before `nz update` touches tracked pack files | One per modpack upgrade you go through |
| **Retention** | `NEGATIVEZONE_BACKUP_RETAIN` newest (default 3) | Latest only — each new upgrade overwrites the previous `.bak` |
| **Size** | 100 MB – 2 GB each, depending on how much you've explored | 3 – 6 GB |
| **Restore = ?** | Manual file copy back into `.minecraft\` | Launch the generated `Craft to Exile 2 (old)` instance |
| **Has launch hooks?** | (file collection, no scripts) | The `(old)` copy has hooks disabled; multiplayer still requires the admin to roll back the server |

Every `nz setup`, `nz update`, or `nz migrate` that replaces an existing
instance also creates a checksum-verified full backup under
`%APPDATA%\PrismLauncher\instances\.negativezone-backups\`. It is used by the
transaction journal and is not the normal player restore interface. If an
operation is interrupted, close Prism and rerun the same command; do not delete
the journal, stage, rollback, or transaction-backup folders.

---

## Snapshot files (periodic state backups)

Every Prism session end runs `nz backup` which snapshots a curated set of
your personal client state. This catches accidents that packwiz-managed
updates don't handle: world corruption from a mod crash, files deleted by
mistake, unexpected pack changes, etc.

### How it works

When the game closes, Prism runs `nz backup` (its PostExitCommand) which:

1. Checks the timestamp of your newest snapshot. If it's less than
   **3 days old** (configurable), the script exits in ~100 ms — no
   perceptible delay before Prism shows the instance as stopped.
2. If a snapshot is due, it copies a curated allow-list into
   `.negativezone\backups\<timestamp>\` using `robocopy` (fast — multi-GB
   Xaero map caches take ~10–20 s).
3. Prunes to the **3 newest** snapshots so disk usage stays bounded.

Each snapshot is a self-contained tree mirroring the original layout under
`.minecraft\`, so restore is just **copy back**.

The update step also forces one snapshot **right before every modpack
update**, so update day always has a fresh restore point even if your last
periodic snapshot was 2 days ago.

### What's snapshotted

By default (lean profile, ~100 MB – 2 GB per snapshot depending on
exploration):

- `XaeroWaypoints\` — every server waypoint you've placed
- `XaeroWorldMap\` — explored map cache (the dominant size term)
- `screenshots\`, `shaderpacks\`, `resourcepacks\`
- `config\jei\` and `config\emi\` (recipe-viewer bookmarks)
- `options.txt`, `optionsof.txt`, `optionsshaders.txt`, `servers.dat`,
  `usercache.json`, `usernamecache.json`
- The **pack-author user-prefs manifest** — every mod-config file the
  pack treats as user-tunable (Embeddium graphics, Oculus shaders, Xaero
  map style, HUD layout, sound prefs, keybinds, etc.). The current list
  lives at `packwiz/.user-prefs.txt` in the repo and is bundled into each
  pack release as `<instance>\.negativezone\preserve-list.json`.

Notably **not** included by default: `.minecraft\saves\` — most players
connect to the multiplayer server so client saves are empty. If you play
single-player worlds in this instance too, opt in with the env var below.

### Tuning or disabling

Open PowerShell and set any of these in your user environment (they
persist across reboots; restart Prism for them to take effect):

| Variable | Purpose | Default |
|----------|---------|---------|
| `NEGATIVEZONE_BACKUP_DAYS` | Days between snapshots (`0` = every exit) | `3` |
| `NEGATIVEZONE_BACKUP_RETAIN` | How many snapshots to keep | `3` |
| `NEGATIVEZONE_BACKUP_INCLUDE_SAVES` | Set to `1` to also snapshot single-player worlds (adds GBs) | unset |
| `NEGATIVEZONE_BACKUP_DISABLE` | Set to `1` to disable backups entirely | unset |

Example — keep 5 weekly snapshots that include single-player worlds:

```powershell
[Environment]::SetEnvironmentVariable('NEGATIVEZONE_BACKUP_DAYS',          '7', 'User')
[Environment]::SetEnvironmentVariable('NEGATIVEZONE_BACKUP_RETAIN',        '5', 'User')
[Environment]::SetEnvironmentVariable('NEGATIVEZONE_BACKUP_INCLUDE_SAVES', '1', 'User')
```

### Restoring user state from a snapshot

1. **Close Prism.**
2. Open `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\`
   in File Explorer.
3. Pick the snapshot you want — folders are named `yyyyMMdd-HHmmss` so the
   newest is alphabetically last.
4. Copy the files/directories you want to restore back into
   `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.minecraft\`,
   overwriting the current ones.
5. Reopen Prism and launch.

---

## Previous-version backup (`.bak` rollback)

When `nz setup` runs an upgrade (finds an existing instance with a
different version), it transactionally installs and validates the new version,
then copies the verified previous payload to `Craft to Exile 2.bak` and creates
a launchable `Craft to Exile 2 (old)` copy. Both sit alongside the current
instance in Prism's **Backup** group.

### What it's for

A safety raft for two narrow cases:

1. **"The new version broke something and the admin hasn't fixed it yet."**
   While the admin rolls the server back (or pushes a hotfix), you've got
   the previous client version ready to go without re-downloading.
2. **Offline play of the old version** — useful if you want to compare
   UI/config behaviour between versions, or replay a single-player world
   built on the old mod set.

### What it's *not* for

- **Joining the live server with a version mismatch.** If you launch the
  `.bak` instance while the server is already on the new version, the server
  will kick you at the FML handshake. The `.bak` is only useful for multiplayer
  if the admin has also rolled the server back to that version.
- **A long-term archive.** Each new upgrade overwrites the previous
  `.bak` — there is no `.bak.bak` deep history. If you want to keep
  an old version forever, copy the `Craft to Exile 2.bak` folder under
  `%APPDATA%\PrismLauncher\instances\` somewhere off-instance before your next
  upgrade.

### Raw `.bak` versus launchable `(old)`

The `.bak` is a byte-for-byte copy of your old instance, including its launch
hooks. Those hooks reference an absolute path that now points at your *current*
instance's `nz.exe`. The generated `Craft to Exile 2 (old)` copy disables those
hooks, so use `(old)` for a clean offline launch. Treat `.bak` as the cold
filesystem rollback source:

- For a **real multiplayer rollback**, the admin rolls the server back and you
  re-run `nz update` (the admin sets `allowDowngrade` in the manifest).
- For **offline single-player** on the old mod set, launch `(old)`.

### Using it

1. In Prism's instance grid, find **Craft to Exile 2 (old)** under **Backup**.
2. Click it, then **Play** as normal. If the server is still on a different
   version, expect an FML-handshake kick on join — that's fine, you're not
   breaking anything.

---

## "Which one do I want?" — restore scenarios

| Symptom | Use | How |
|---|---|---|
| Lost a single waypoint / setting after an update | Snapshot files | Copy that one file/dir from the newest snapshot back into `.minecraft\` |
| All my Xaero waypoints + explored map are gone | Snapshot files | Copy back `XaeroWaypoints\` and `XaeroWorldMap\` from the newest snapshot |
| Keybinds reset | Snapshot files | Copy `options.txt` back |
| Server list cleared / lost the entry | Snapshot files | Copy `servers.dat` back |
| The new modpack version has a client-side bug; I need to play yesterday's version while the admin fixes it | Previous-version copy | Launch `Craft to Exile 2 (old)`. It only works for multiplayer if the admin also rolled back. |
| I want yesterday's modpack *and* my latest waypoints | Both | Launch `(old)` once to verify it boots, then copy `XaeroWaypoints\` from the newest snapshot into that instance's `.minecraft\` |
| Something deleted my whole `.minecraft\config\` directory | Snapshot files (partial) + re-run install (full) | Restore the pack-author preserve-list files from snapshot for your tunings, then re-run the Path A one-liner to repopulate the rest of the configs from the pack defaults |

---

## Disk usage at a glance

Worst-case footprint of the safety net (without `NEGATIVEZONE_BACKUP_INCLUDE_SAVES`):

- 3 snapshot folders × up to ~2 GB each = ~6 GB
- `.bak` plus `(old)` ≈ 6–12 GB after a setup upgrade
- one 3–6 GB immutable full backup for each changing setup, update, or migration

Transaction backups are intentionally not automatically pruned. If disk usage
becomes a problem, send `nz support` output to the admin before removing old,
completed transaction directories.

If you turn on single-player saves in snapshots, multiply the snapshot
portion by however large your `saves/` directory is.
