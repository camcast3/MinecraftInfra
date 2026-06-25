---
layout: default
title: Updates
nav_order: 3
---

# Modpack updates
{: .no_toc }

How new modpack versions reach your client, and what to do when you see a
"version mismatch" block.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

---

## TL;DR

- Every time you click **Play**, a ~1-second check compares your installed
  modpack version to the server's current version.
- **If you match:** the game launches normally, no extra delay.
- **If you don't match:** Prism shows a hard block with on-screen instructions
  telling you to run a one-line update command. Re-launch after running it.
- **If GitHub is unreachable:** the check fails open so offline play still works.

You're never auto-updated *during* launch any more — the update is a
**deliberate action you take from a separate PowerShell window**, so you're
never surprised by a multi-minute "Running pre-launch command" delay with no
progress bar.

---

## How the launch-time check works

When you click **Play**, Prism runs `prelaunch-check.ps1`. The script:

1. Reads your installed version from
   `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone-version`.
2. Fetches a ~10-byte pointer file from `raw.githubusercontent.com`
   (CDN-cached, free, ~100 ms).
3. Compares the two as strict equality.

**Cost:** one tiny GET per launch. GitHub's CDN serves it, so we don't pay
Azure egress per player launch, and you don't depend on the modpack blob
being warm.

**Outcomes:**

| Installed | Server | Result |
|---|---|---|
| `0.4.2` | `0.4.2` | Silent pass — game launches |
| `0.4.1` | `0.4.2` | Hard block, "behind" — run the update one-liner |
| `0.5.0` | `0.4.2` | Hard block, "ahead" — usually means a rollback is needed |
| anything | unreachable (no internet, 404, 5xx) | Pass with `allowing launch` notice; offline play works |

---

## What the block looks like

When your version doesn't match, you'll see this in Prism's pre-launch
console window:

```
[negativezone] ============================================================
[negativezone]   MODPACK VERSION MISMATCH
[negativezone]   installed: v0.4.1
[negativezone]   server:    v0.4.2  (behind)
[negativezone] ============================================================
[negativezone]
[negativezone] The server is pinned to a specific modpack version. Joining
[negativezone] with a different client version would fail at the FML handshake.
[negativezone]
[negativezone] Run this in a NEW PowerShell window (close Prism first):
[negativezone]
[negativezone]   irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/update.ps1 | iex
[negativezone]
[negativezone] (Set $env:NEGATIVEZONE_SKIP_VERSION_CHECK=1 to bypass for offline play.)
```

The direction hint (`behind` or `ahead`) tells you what's going on:

- **`behind`** — you're on an older version. Run the update one-liner.
- **`ahead`** — you're on a newer version than the server. This usually means
  you tested a pre-release and the server hasn't moved up to it yet, or the
  admin rolled the server back to fix a bug. Re-run the update one-liner —
  by default it refuses to "downgrade" you, so the admin will need to set
  `allowDowngrade: true` in the manifest. Reach out and they'll do it.

---

## Updating manually

When you see the block:

1. **Close Prism completely** (file → quit, or close the window). The update
   script swaps files in your instance and can't do that while Prism has them
   open.
2. **Open a NEW PowerShell window** (Windows key → `powershell` → Enter).
3. **Paste and run:**

   ```powershell
   irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/update.ps1 | iex
   ```

4. The script:
   - Snapshots your current state first (waypoints, options, etc. — see [Backups]({% link backups.md %})).
   - Downloads the new modpack zip from our Azure storage, verifies the SHA-256.
   - Atomically swaps in the new mods, configs, and resourcepacks.
   - Preserves the pack-author-flagged user prefs (graphics tuning, shader
     choice, recipe-viewer bookmarks, keybinds, HUD layout, etc.) — those
     don't get reset by the update.
   - Bumps your `.negativezone-version` marker to match the server.

5. **Reopen Prism, click Play.** The version check now silent-passes, the
   game launches normally.

A typical update takes **30–90 seconds** depending on your internet speed
and how big the version delta is.

> **Resetting a tuned setting back to pack defaults:** Just delete the
> relevant config file from `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.minecraft\config\`
> (e.g. `embeddium-options.json`, `oculus.properties`) — the next pack
> update will reseed the pack-recommended baseline. The pack ships
> opinionated defaults for graphics, shaders, and UI on first install;
> from there it's yours to tweak.

---

## Restoring settings from your old instance (manual)

If you upgraded and a config, keybind, or map you'd tuned didn't carry
over, you can copy it back from the previous version's instance. Every
upgrade leaves two recovery sources alongside the live install:

- **`Craft to Exile 2 (old)`** — a launchable copy of the previous
  version, visible in Prism under the **Backup** group.
- **`%LOCALAPPDATA%\NegativeZone\archives\Craft to Exile 2_v<prev>_<timestamp>.zip`** —
  a permanent zip of the previous version, outside Prism's instances dir
  so it's never overwritten by future upgrades.

The simplest path is to copy from the **(old)** instance. Do this with
Prism's main window closed (file locks otherwise).

### Steps

1. In Prism, right-click **`Craft to Exile 2 (old)`** → **Folder**. A
   File Explorer window opens at the old instance's root.
2. Double-click into **`.minecraft\`**.
3. Select these items (only the ones that exist):
   - **`config\`** — every mod config (graphics, keybinds, HUD layout,
     recipe-viewer prefs, etc.)
   - **`options.txt`** — vanilla keybinds + video settings
   - **`optionsof.txt`** — OptiFine settings (if installed)
   - **`XaeroWaypoints\`** + **`XaeroWorldMap\`** — Xaero map data
   - **`journeymap\`** — JourneyMap waypoints + tile cache (if installed)
   - **`hotbar.nbt`** — creative-mode hotbar saves (if you use them)
4. Copy them (`Ctrl+C`).
5. Switch back to Prism, right-click **`Craft to Exile 2`** (the new
   live instance) → **Folder**, then double-click into **`.minecraft\`**.
6. Paste (`Ctrl+V`). When prompted to overwrite, click **Replace the
   files in the destination**.
7. Close both File Explorer windows. Launch the live instance.

> **Do NOT copy `mods\`, `libraries\`, or `versions\`** from the old
> instance — those are the modpack itself, and overwriting them puts
> you back on the previous version's mods (the server will kick you at
> the FML handshake). Stick to the list above.

### If you don't see a `(old)` instance

You installed before the side-by-side restore was added. Try in order:

1. **`%APPDATA%\PrismLauncher\instances\Craft to Exile 2.bak\`** — the
   immediate pre-upgrade snapshot. Same `.minecraft\` layout inside;
   copy the same items as above.
2. **`%LOCALAPPDATA%\NegativeZone\archives\*.zip`** — extract the
   newest zip and copy from `<extracted>\Craft to Exile 2\.minecraft\`.
3. **`%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\<timestamp>\`** —
   a periodic snapshot (every 3 days; one is forced just before each
   update). Smaller scope than the above two but always present after
   a few launches.

### Or: use the migrate helper

The `migrate-settings.ps1` script automates this whole flow with a
confirm-before-overwrite prompt, including auto-detecting Prism and
CurseForge instances. Run it from a new PowerShell window:

```powershell
irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/migrate-settings.ps1 | iex
```

It asks for the **source** (old instance) and **destination** (new
instance), previews what will be copied, and backs up anything it
overwrites to a timestamped folder so the operation is reversible.

---

## Bypassing the check (offline play)

If you want to launch a known-mismatched client (e.g. the server is down
and you just want to wander a single-player world), set this in your user
environment **once**:

```powershell
[Environment]::SetEnvironmentVariable('NEGATIVEZONE_SKIP_VERSION_CHECK', '1', 'User')
```

Close and reopen Prism for the env var to take effect. The version check
will print one line saying it's bypassed and let you launch. Note that the
**multiplayer server will kick you at the FML handshake** if your mods
don't match — this bypass is only for offline / dev work. Unset by setting
the value to an empty string and restarting Prism.

You can also disable the check by unchecking **Custom commands** in Prism
(instance → **Edit** → **Settings** → **Custom commands**), but that also
disables the periodic backup hook, so prefer the env var.

---

## Migration note (existing v0.4.x players)

If you installed before the launch-time version-check system shipped, your
instance doesn't have `prelaunch-check.ps1` yet — it only lands during a
re-run of the setup one-liner. Until you've re-run it once:

- You **won't** see the hard block above.
- You **will** see the server's current version in Prism's server-list MOTD —
  it shows `Craft to Exile 2 v0.4.X` next to the green status dot. When you
  notice that number is different from your installed version (visible in
  the instance name in Prism's grid), that's your cue to upgrade.

**To opt in to the launch-time check**, re-run the Path A one-liner once:

```powershell
irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 | iex
```

It preserves your worlds, waypoints, options, and any other user state.
From your next launch onward, the version check runs automatically and the
MOTD version label becomes redundant (we'll likely drop it from the MOTD
once everyone has migrated).

---

## Release cadence

What you can expect from each version bump:

| Bump | Example | What it means for you |
|---|---|---|
| **PATCH** | `0.4.1` → `0.4.2` | Client-only change (config tweak, single-mod swap, performance fix). Server keeps running. Re-run the update one-liner from the block banner, you're good. |
| **MINOR** | `0.4.x` → `0.5.0` | Client + server in sync — usually a new mod or a major mod upgrade that needs the server-side too. The server briefly restarts on publish (~30 sec); you might see "Server unavailable" for a moment. |
| **MAJOR** | `0.x.y` → `1.0.0` | Reserved for "we've gone a full month without management-caused downtime" — a stability milestone, not a content gate. |

The strict-equality check blocks every delta — including PATCH — until the
update pipeline is rock-solid in production. We may relax this to
"MINOR-or-greater only" once a few real releases have been exercised
end-to-end without surprises.
