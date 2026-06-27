---
layout: default
title: Player walkthrough
nav_order: 3
---

# Player walkthrough
{: .no_toc }

Every manual action you ever take as a player, in one place — what triggers
it, the exact command, and what it does. If you just want to install and play,
follow [Get started]({% link setup.md %}); come back here when you want the
"what do I actually have to run by hand?" reference.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

---

## Manual vs automated — the one-screen summary

You run **three** things by hand, ever. Everything else happens automatically
when you click Play or quit the game.

| Action | You do it? | How |
|---|---|---|
| **First install** | **Manual** (once per PC) | Paste the one-line installer into PowerShell |
| **Play / version check** | Automatic | Prism runs `nz check` before every launch |
| **Backup on quit** | Automatic | Prism runs `nz backup` after every session |
| **Update when prompted** | **Manual** | Double-click **Update Craft to Exile 2** on your Desktop |
| **Move to a new PC** | **Manual** (rare) | Run `nz migrate` after installing on the new PC |
| **Offline / bypass the gate** | **Manual** (rare) | Set one environment variable |

Everything runs through a single small program, `nz.exe`, that the installer
drops in two places:

- `%LOCALAPPDATA%\NegativeZone\nz.exe` — your personal copy (use this for
  ad-hoc commands).
- `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\nz.exe` —
  the copy Prism's launch/exit hooks call automatically.

> The legacy PowerShell scripts (`setup.ps1`, `update.ps1`,
> `migrate-settings.ps1`) are **deprecated** — use the `nz` commands below.

---

## 1. First install (manual, once per PC)

**Why** — get Java 17, Prism Launcher, and the Craft to Exile 2 modpack onto a
new PC and wire up the auto-update / auto-backup hooks.

**Prerequisites**

- Windows 10/11 with a **paid Minecraft Java Edition** account.
- 8 GB+ total system RAM (the modpack instance ships pinned to an 8 GB allocation).
- `winget` (ships with Windows 10/11; otherwise install
  [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1)).

**How** — press **Windows key** → type `powershell` → **Enter**, then paste:

```powershell
irm https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/install.ps1 | iex
```

**What it does**

1. Installs **Java 17 (Temurin)** + **Prism Launcher** via winget (skips either
   if already present).
2. Downloads `nz.exe` to `%LOCALAPPDATA%\NegativeZone\nz.exe`.
3. Runs `nz setup`: pulls the modpack zip from Azure (SHA-256 verified),
   installs it as the **Craft to Exile 2** Prism instance, writes the
   `.negativezone-version` marker, wires Prism's **PreLaunchCommand**
   (`nz check`) and **PostExitCommand** (`nz backup`), and drops an
   **Update Craft to Exile 2** launcher on your Desktop.

**Notes**

- **Safe to re-run.** On an existing install it upgrades in place, preserves
  your worlds/waypoints/settings, and keeps the previous version as a
  `Craft to Exile 2.bak` folder for rollback.
- **Already on the old PowerShell-script install?** **v0.5.0 is the cutover to
  the nz client** — its new mods mean you must upgrade to keep playing, and
  re-running the one-liner above is the whole migration. Details:
  [Upgrading to v0.5.0]({% link updates.md %}#upgrading-to-v050).
- Override the binary/manifest with `NEGATIVEZONE_NZ_EXE_URL` /
  `NEGATIVEZONE_MANIFEST_URL`, or skip the winget step with
  `NEGATIVEZONE_SKIP_WINGET=1` (admins/testing only).
- Full walk-through, including a manual fallback: [Get started]({% link setup.md %}).

---

## 2. Play (automatic — no action)

**Why** — stop you joining with a mismatched modpack version (which would fail
at the Forge/FML handshake).

**How** — nothing. Prism runs this for you as the **PreLaunchCommand**:

```text
"…\Craft to Exile 2\.negativezone\nz.exe" check
```

**What it does** — reads your `.negativezone-version`, fetches the server's
`latest-version.txt`, and compares them:

| Installed vs server | Result |
|---|---|
| Match | Silent pass — game launches |
| Behind / ahead | Hard block with `MODPACK VERSION MISMATCH` and update instructions |
| Server unreachable (offline, 404, 5xx) | Fails **open** — launch allowed |

**Notes** — when blocked, the console tells you to run `nz update`; the easy way
is **action 4** below. See [Updates]({% link updates.md %}) for the full block
anatomy.

---

## 3. Backup on quit (automatic — no action)

**Why** — keep rolling snapshots of your personal state (waypoints, maps,
options, shaders, tuned configs) so a bad update or crash is recoverable.

**How** — nothing. Prism runs this as the **PostExitCommand** after every
session:

```text
"…\Craft to Exile 2\.negativezone\nz.exe" backup
```

**What it does** — at most once per **3 days** of play, copies a curated
allow-list into
`%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\<yyyyMMdd-HHmmss>\`,
keeping the **3** newest. A fresh snapshot is also forced right before every
update.

**Notes** — tune or disable with user environment variables (restart Prism to
apply):

| Variable | Purpose | Default |
|---|---|---|
| `NEGATIVEZONE_BACKUP_DAYS` | Days between snapshots (`0` = every exit) | `3` |
| `NEGATIVEZONE_BACKUP_RETAIN` | Snapshots to keep | `3` |
| `NEGATIVEZONE_BACKUP_INCLUDE_SAVES` | `1` to also snapshot single-player worlds | unset |
| `NEGATIVEZONE_BACKUP_DISABLE` | `1` to disable entirely | unset |

Restore details: [Backups]({% link backups.md %}).

---

## 4. Update when prompted (manual)

**Why** — a new modpack version shipped and the launch-time check is blocking
you (or you just want to pull the latest).

**Prerequisites** — **close Prism completely first** (the update touches
instance files Prism holds open).

**How** — **double-click `Update Craft to Exile 2` on your Desktop.** That's it.

Prefer a terminal? Open a **new** PowerShell window and run:

```powershell
& "$env:LOCALAPPDATA\NegativeZone\nz.exe" update
```

**What it does**

1. Auto-detects the Craft to Exile 2 instance and refuses to run while Prism is
   open.
2. Forces a pre-update safety snapshot.
3. Delta-syncs `.minecraft` with `packwiz-installer` against the server's
   SHA-pinned `pack.toml` — only changed modpack files download (usually
   10–50 MB), so your personal state stays put.
4. Bumps `.negativezone-version` to match the server.

**Notes**

- **Safe to re-run / no-op aware** — if you're already current it does nothing.
- Refuses downgrades unless the admin sets `allowDowngrade` in the manifest.
- Deep dive: [Updates]({% link updates.md %}).

---

## 5. Move to a new PC (manual, rare)

**Why** — carry your keybinds, video/shader options, and Xaero/JourneyMap
waypoints from an old install to a freshly installed one.

**Prerequisites** — run the **first-install** one-liner (action 1) on the new
PC, and have the **old instance folder** reachable (copied over, on a USB
drive, etc.).

**How** — in PowerShell:

```powershell
& "$env:LOCALAPPDATA\NegativeZone\nz.exe" migrate
```

It auto-detects Prism/CurseForge instances and prompts you to pick the **source**
(old) and **destination** (new). You can also pass paths explicitly:

```powershell
& "$env:LOCALAPPDATA\NegativeZone\nz.exe" migrate --from "D:\old\Craft to Exile 2" --to "$env:APPDATA\PrismLauncher\instances\Craft to Exile 2"
```

**What it does** — previews a plan, then copies `options.txt`, `optionsof.txt`,
`optionsshaders.txt`, `hotbar.nbt`, and the `journeymap` / `XaeroWaypoints` /
`XaeroWorldMap` folders. Anything it overwrites is first moved to a
`_migration-backup-<timestamp>\` folder, so it's reversible.

**Notes**

- `servers.dat` is **not** copied (the pack ships its own server entry).
- Mod configs under `config/` are **not** bulk-copied — port them one mod at a
  time if needed (bulk-copying across versions can crash the game).

---

## 6. Offline / bypass the gate (manual, rare)

**Why** — launch a known-mismatched client on purpose (e.g. play a
single-player world while the server is down).

**How** — set it once in your user environment, then restart Prism:

```powershell
[Environment]::SetEnvironmentVariable('NEGATIVEZONE_SKIP_VERSION_CHECK', '1', 'User')
```

**What it does** — `nz check` prints one line saying it's bypassed and lets the
game launch regardless of version.

**Notes** — the **multiplayer server still kicks you** at the FML handshake if
your mods don't match; this is for offline/dev use only. Undo by setting the
value to an empty string and restarting Prism.

---

## 7. Send logs to the admin (manual, when asked)

**Why** — something went wrong and the admin asks for your logs.

**How** — in PowerShell:

```powershell
& "$env:LOCALAPPDATA\NegativeZone\nz.exe" support
```

**What it does** — bundles `nz.log` (the full-detail record every `nz` command
writes to `.negativezone\nz.log`), the installed-version marker, `instance.cfg`,
and a short environment summary into `nz-support-<timestamp>.zip` on your
**Desktop**. DM that single file to the admin.

**Notes**

- Want to watch a command in detail live? Add `--verbose` (e.g. `nz update
  --verbose`). `nz.log` always has the full detail regardless of the flag.
- `--quiet` shows errors only on the console.

---

## Where to go deeper

| Topic | Page |
|---|---|
| First install (friendly + manual fallback) | [Get started]({% link setup.md %}) |
| The launch-time check & updating in detail | [Updates]({% link updates.md %}) |
| Snapshots, rollback, restore scenarios | [Backups]({% link backups.md %}) |
| Something went wrong | [Troubleshooting]({% link troubleshooting.md %}) |
