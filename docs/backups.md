---
layout: default
title: Backups
nav_order: 4
---

# Backups & restore
{: .no_toc }

Two completely separate backup mechanisms protect your client, with
different purposes. Worth knowing the distinction before you actually need
to restore something.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

---

## The two mechanisms at a glance

|  | **Snapshot files** | **Backup instance** |
|---|---|---|
| **What it is** | Timestamped folders of your personal state files | A full second Prism instance (entire copy of the modpack at the *previous* version) |
| **Where** | `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\<yyyyMMdd-HHmmss>\` | Prism's main grid, under the **Backup** group, named like `Craft to Exile 2 v0.4.1` |
| **Contains** | Waypoints, world map cache, shaders, resourcepacks, options, recipe bookmarks, plus pack-author-flagged config files (graphics, shaders, HUD, sound prefs, keybinds) | Mods, configs, resourcepacks, libraries — the whole game install at the prior version |
| **Does *not* contain** | Single-player worlds (opt-in), mods, configs not in the pack-author preserve list | — (it's a complete instance) |
| **Created by** | `backup.ps1` PostExit hook (every Prism close) | `setup.ps1` when it detects an upgrade (existing instance, different version) |
| **Cadence** | At most once per `NEGATIVEZONE_BACKUP_DAYS` (default 3 days) of play; one is also forced just before `update.ps1` swaps files | One per modpack upgrade you go through |
| **Retention** | `NEGATIVEZONE_BACKUP_RETAIN` newest (default 3) | Latest only — each new upgrade overwrites the previous Backup |
| **Size** | 100 MB – 2 GB each, depending on how much you've explored | 3 – 6 GB |
| **Restore = ?** | Manual file copy back into `.minecraft\` | Click **Play** on the Backup instance |
| **Has launch hooks?** | (file collection, no scripts) | **No, intentionally frozen** — no version check, no PostExit snapshot. It's the recovery raft. |

---

## Snapshot files (periodic state backups)

Every Prism session end runs `backup.ps1` which snapshots a curated set of
your personal client state. This catches accidents that the modpack-update
preserve list doesn't handle: world corruption from a mod crash, files
deleted by mistake, modpack updates that wipe a directory we didn't think
to preserve, etc.

### How it works

When the game closes, Prism runs `backup.ps1` which:

1. Checks the timestamp of your newest snapshot. If it's less than
   **3 days old** (configurable), the script exits in ~100 ms — no
   perceptible delay before Prism shows the instance as stopped.
2. If a snapshot is due, it copies a curated allow-list into
   `.negativezone\backups\<timestamp>\` using `robocopy` (fast — multi-GB
   Xaero map caches take ~10–20 s).
3. Prunes to the **3 newest** snapshots so disk usage stays bounded.

Each snapshot is a self-contained tree mirroring the original layout under
`.minecraft\`, so restore is just **copy back**.

The update script also forces one snapshot **right before every modpack
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

## Backup instance (frozen rollback)

When `setup.ps1` runs an upgrade (finds an existing instance with a
different version), it renames the old instance to `<name>.bak` before
installing the new version. The renamed instance ends up in a **Backup**
group in Prism's grid, sitting alongside the current **Latest**.

### What it's for

A safety raft for two narrow cases:

1. **"The new version broke something and the admin hasn't fixed it yet."**
   While the admin rolls the server back (or pushes a hotfix), you've got
   the previous client version ready to go without re-downloading.
2. **Offline play of the old version** — useful if you want to compare
   UI/config behaviour between versions, or replay a single-player world
   built on the old mod set.

### What it's *not* for

- **Joining the live server with a version mismatch.** If you click Play
  on the Backup instance while the server is already on the new version,
  the server will kick you at the FML handshake. The Backup is only useful
  for multiplayer if the admin has also rolled the server back to that
  version.
- **A long-term archive.** Each new upgrade overwrites the previous
  Backup — there is no `Backup.bak.bak` deep history. If you want to keep
  an old version forever, copy the `Craft to Exile 2 v0.X.Y` folder under
  `%APPDATA%\PrismLauncher\instances\` somewhere off-instance.

### Why it has no launch hooks

The Backup instance has its `PreLaunchCommand` and `PostExitCommand`
deliberately left empty:

- **No version check** — the whole point is launching a known-mismatched
  client. Blocking it would defeat the purpose.
- **No PostExit backup** — we don't want the recovery raft to snapshot
  itself; that would mix old-version state into the snapshot history.

It is genuinely frozen. Click Play, do what you need, exit, no automation
runs.

### Using it

1. In Prism, expand the **Backup** group in the instance grid.
2. Click **Craft to Exile 2 v0.X.Y** (the version below your current one).
3. **Play** as normal. If the server is still on a different version, expect
   an FML-handshake kick on join — that's fine, you're not breaking anything.

---

## "Which one do I want?" — restore scenarios

| Symptom | Use | How |
|---|---|---|
| Lost a single waypoint / setting after an update | Snapshot files | Copy that one file/dir from the newest snapshot back into `.minecraft\` |
| All my Xaero waypoints + explored map are gone | Snapshot files | Copy back `XaeroWaypoints\` and `XaeroWorldMap\` from the newest snapshot |
| Keybinds reset | Snapshot files | Copy `options.txt` back |
| Server list cleared / lost the entry | Snapshot files | Copy `servers.dat` back |
| The new modpack version has a client-side bug; I need to play yesterday's version while the admin fixes it | Backup instance | Click Play on the Backup instance. Only works for the multiplayer server if admin also rolled back. |
| I want yesterday's modpack *and* my latest waypoints | Both | Click Play on Backup once to verify it boots, then copy `XaeroWaypoints\` from the newest snapshot into the Backup instance's `.minecraft\` |
| Something deleted my whole `.minecraft\config\` directory | Snapshot files (partial) + re-run setup (full) | Restore the pack-author preserve-list files from snapshot for your tunings, then re-run the Path A one-liner to repopulate the rest of the configs from the pack defaults |

---

## Disk usage at a glance

Worst-case footprint of the safety net (without `NEGATIVEZONE_BACKUP_INCLUDE_SAVES`):

- 3 snapshot folders × up to ~2 GB each = ~6 GB
- 1 Backup instance ≈ 3–6 GB
- **Total ≈ 9–12 GB** under `%APPDATA%\PrismLauncher\instances\`

If you turn on single-player saves in snapshots, multiply the snapshot
portion by however large your `saves/` directory is.
