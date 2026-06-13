---
layout: default
title: Player Onboarding
nav_order: 2
---

# Player Onboarding Guide
{: .no_toc }

Two paths to get connected: a **one-line automated setup** (recommended) or
**manual step-by-step** if you'd rather see what's happening.

> **Already playing?** A new auto-update launch hook and periodic backup
> hook are now part of the Craft to Exile 2 instance. **Re-run the setup
> one-liner once** (see [Path A](#path-a--automated-setup-recommended)) to
> enable zero-action modpack updates and periodic snapshots of your
> personal state on your installed instance. After that, future modpack
> publishes apply automatically on the next Prism launch — no manual
> action required. See [Modpack updates](#modpack-updates) and
> [Periodic backups](#periodic-backups) for how they work.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

---

## What you'll need before starting

- A Windows 10/11 PC
- A **paid Minecraft Java Edition** account (Bedrock from Xbox / Microsoft Store / mobile **does not work**)

> **Don't have Minecraft Java yet?** Get it from
> [minecraft.net/store/minecraft-java-edition](https://www.minecraft.net/en-us/store/minecraft-java-edition).

### System requirements

[C2E2's official recommendation](https://github.com/mahjerion/Craft-to-Exile-2/wiki/Installation)
is **4–8 GB allocated** to Minecraft. Don't over-allocate — on systems with
only 8 GB total, giving Minecraft 8 GB will starve Windows and crash the game.

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| RAM (total system) | 8 GB | 16+ GB |
| RAM allocated to Minecraft | 4 GB | 8 GB |
| CPU | 4 cores | 4+ cores, 3 GHz+ |
| Storage | 10 GB free | 20+ GB on SSD |

> The automated setup (Path A) **detects your installed RAM and allocates
> half to Minecraft, capped at 12 GB** (per C2E2's "don't over-allocate"
> warning) — you don't need to touch Prism's Java or memory settings.
> Setup refuses to install if you have less than 8 GB total system RAM,
> because the modpack won't run reliably below that.

---

## Path A — Automated setup (recommended)

A single PowerShell command installs **Java 17**, **Prism Launcher**, the
**Craft to Exile 2 modpack** (pulled directly from our Azure storage — much
faster than CurseForge), **auto-tunes the memory allocation** to fit your
PC, looks up your **UUID**, and copies the allowlist info to your clipboard.
~3 minutes.

### Run it

1. Press the **Windows key**, type `powershell`, press **Enter**
2. Copy-paste this command and press **Enter**:

   ```powershell
   irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 | iex
   ```

3. Approve any winget prompts (press **Y** + Enter if asked)
4. When prompted, type your **Minecraft Java username** and press **Enter**
5. The script copies `Username: ... / UUID: ...` to your clipboard

> **Cautious? Verify before running.** The script is published as a GitHub
> Release asset with a SHA-256 hash you can check. See
> [Releases](https://github.com/camcast3/MinecraftInfra/releases?q=setup-v) —
> each release shows the install command and a copy-paste verification
> one-liner that refuses to run if the file has been tampered with.

> **What about the modpack zip?** The script also verifies the SHA-256 of
> the modpack zip pulled from our storage before installing it. If anything
> tampers with it, the install aborts.

### After the script finishes

1. **DM the admin** — paste with **Ctrl+V** to send your username + UUID. Wait for confirmation you're allowlisted.
2. Open **Prism Launcher** from the Start menu
3. **Sign in with your Microsoft account** (the one that owns Minecraft Java)
4. Launch the **Craft to Exile 2** instance (already installed by the script)
5. **Multiplayer → Add Server**, server address: `mc.negativezone.cc`
6. Join — you'll be auto-connected straight into Craft to Exile 2.

That's it. The remaining sections below are only needed if the automated
script didn't work or you want manual control.

---

## Path B — Manual setup

Follow these if Path A errored out, or if you'd rather do every step yourself.

### Step 1 — Get your username and UUID

The server is **allowlist-only**. The admin needs your Minecraft Java
**username** and **UUID** before you can join.

Use [**minecraftuuid.com**](https://minecraftuuid.com/):

1. Open [minecraftuuid.com](https://minecraftuuid.com/)
2. Type your Minecraft Java username in the search box, press **Enter**
3. Copy your **username** and the **Full UUID** (the one with dashes, e.g. `a30918db-b4fe-4659-9575-ebc8c19640b8`)

DM the admin:

```
Username: <your-username>
UUID: <your-uuid>
```

Wait for confirmation that you've been added.

### Step 2 — Install Java 17

Minecraft 1.20.1 requires **Java 17** specifically (not 8, not 21).

**Check if it's already there:**

1. Press the **Windows key**, type `powershell`, press **Enter**
2. Run:
   ```powershell
   java -version
   ```
3. If it says `version "17.x.x"`, skip to Step 3.

**Install via winget** (Windows' built-in package manager):

```powershell
winget install --id EclipseAdoptium.Temurin.17.JDK -e --source winget
```

Approve any prompts (press **Y** if asked). winget auto-configures `JAVA_HOME`
and PATH. Close and reopen PowerShell, then verify with `java -version`.

> **`winget` not found?** You're on an older Windows build. Install
> [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1) from the
> Microsoft Store, which includes winget.

### Step 3 — Install Prism Launcher

Prism Launcher is a free, open-source Minecraft launcher that handles modpacks
in one click. Install via winget:

```powershell
winget install --id PrismLauncher.PrismLauncher -e --source winget
```

Or download the installer from [prismlauncher.org/download/windows](https://prismlauncher.org/download/windows/).

### Step 4 — Set up Prism

1. Open **Prism Launcher** from your Start menu
2. **Sign in with your Microsoft account** — click **Microsoft**, then **Open the
   page and copy the code**, paste it in your browser, and sign in with the same
   Microsoft account that owns Minecraft Java

3. Click **Settings** (top-right) → **Java** tab:
   - Click **Auto-detect...** → select the **Java 17** entry → **OK**
   - Under **Memory**, set **Maximum memory allocation** to **`8192`** (= 8 GB)
     - If your PC has only 8 GB RAM total, use `4096` instead
     - Per [C2E2's docs](https://github.com/mahjerion/Craft-to-Exile-2/wiki/Installation),
       **don't go above 8 GB** — allocating 12+ GB causes garbage-collection
       stalls and crashes.

   Click **OK** to save.

### Step 5 — Install the Craft to Exile 2 modpack

1. Back at Prism's main window, click **Add Instance** (top-left)
2. Click **CurseForge** in the left sidebar
3. Search **`Craft to Exile 2`** and press Enter
4. Click the result (icon is a brown leather book) → leave **Version** at latest → **OK**

Prism downloads Forge + all the mods (5–15 min depending on your internet).

> **⚠️ Do NOT install extra mods.** The server checks that your mod list matches
> the modpack exactly. Adding random mods gets you kicked.

### Step 6 — Connect to the server

1. Select the **Craft to Exile 2** instance in Prism → click **Launch**
2. Once Minecraft loads, click **Multiplayer** → **Add Server**
3. Fill in:
   - **Server Name:** `NegativeZone`
   - **Server Address:** `mc.negativezone.cc`
4. Click **Done**, then double-click the server to join

You'll be **automatically forwarded straight into Craft to Exile 2**. If C2E2
is restarting, you'll get a "Server unavailable" message — wait a minute and
try again.

---

## Modpack updates

Once you've installed the modpack (via Path A, or Path B + the setup
one-liner re-run), **updates apply automatically** on the next Prism launch.
You don't need to download anything manually or re-run the setup script.

### How it works

When you click **Launch** in Prism, a small script runs first that:

1. Checks our published manifest at
   `stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest.json`
   to see if a new modpack version is available.
2. If you're already up to date, the game launches normally — no delay.
3. If a new version is available, the script downloads it, verifies the
   SHA-256 hash, and atomically swaps in the new mods, configs, and
   resource packs. Your **worlds (`saves/`), screenshots, and personal
   options stay intact.**
4. The game then launches the freshly updated instance.

A typical update takes **30–60 seconds** before the game starts, depending
on your internet speed and how much the modpack changed.

### Failure behavior

The update is designed to fail-safe in both directions:

- **No internet, or our blob storage is down (fail-open):** the update step
  gives up quickly and lets the game launch with whatever you currently
  have installed. (The server may kick you if your mod set is too stale —
  that's covered in the troubleshooting table.)
- **Corrupted download / SHA-256 mismatch (fail-closed):** the update
  **blocks the launch** rather than installing a broken modpack. You'll see
  an error in the Prism launch log. Re-launch — the next attempt usually
  succeeds.
- **Major version bump (Minecraft version or Forge version changed):** the
  update refuses to swap automatically and asks you to re-run the setup
  one-liner so you get a full clean reinstall.

### Disabling auto-update

If you need to launch without the update step (e.g. you're testing custom
mods locally and don't want them overwritten), uncheck **Custom commands**
in Prism: select the instance → **Edit** → **Settings** → **Custom commands**
tab → uncheck **Custom commands**. Note that **the server will kick you if
your mod set doesn't match** — this escape hatch is for offline / dev work
only. Unchecking **Custom commands** also disables the periodic backup
hook described below, so re-enable it once you're done testing.

---

## Periodic backups

Alongside auto-update, every game session ends by snapshotting a curated
set of your personal client state. This catches accidents that auto-update
preserves don't handle: world corruption from a mod crash, deletions you
made by mistake, modpack updates that wipe a directory we didn't think to
preserve, etc.

### How it works

When the game closes, Prism runs a small script (`backup.ps1`) that:

1. Checks the timestamp of your newest snapshot. If it's less than
   **3 days old**, the script exits immediately (~100 ms — no perceptible
   delay before Prism shows the instance as stopped).
2. If a snapshot is due, it copies a curated allow-list into
   `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\<timestamp>\`
   using `robocopy` (fast — multi-GB Xaero map caches take ~10–20 s).
3. Prunes to the **3 newest** snapshots so disk usage stays bounded.

Each snapshot is a self-contained tree mirroring the original layout under
`.minecraft\`, so restore is just **copy back**.

The auto-update step also forces one snapshot **right before every modpack
update**, so update day always has a fresh restore point even if your last
periodic snapshot was 2 days ago.

### What's snapshotted

By default (lean profile, ~100 MB – 2 GB per snapshot depending on how
much you've explored):

- `XaeroWaypoints\` — every server waypoint you've placed
- `XaeroWorldMap\` — explored map cache (the dominant size term)
- `screenshots\`, `shaderpacks\`, `resourcepacks\`
- `options.txt`, `optionsof.txt`, `optionsshaders.txt`, `servers.dat`,
  `usercache.json`, `usernamecache.json`
- `config\jei\` and `config\emi\` (recipe bookmarks)

Notably **not** included by default: `.minecraft\saves\` — most players
connect to the multiplayer server so client saves are empty. If you play
single-player worlds in this instance too, opt in with the env var below.

### Tuning or disabling

Open PowerShell and set any of these in your user environment (they
persist across reboots):

| Variable | Purpose | Default |
|----------|---------|---------|
| `NEGATIVEZONE_BACKUP_DAYS` | Days between snapshots (set `0` for every exit) | `3` |
| `NEGATIVEZONE_BACKUP_RETAIN` | How many snapshots to keep | `3` |
| `NEGATIVEZONE_BACKUP_INCLUDE_SAVES` | Set to `1` to also snapshot single-player worlds (adds GBs) | unset |
| `NEGATIVEZONE_BACKUP_DISABLE` | Set to `1` to disable backups entirely | unset |

Example — keep 5 weekly snapshots that include SP worlds:

```powershell
[Environment]::SetEnvironmentVariable('NEGATIVEZONE_BACKUP_DAYS',          '7', 'User')
[Environment]::SetEnvironmentVariable('NEGATIVEZONE_BACKUP_RETAIN',        '5', 'User')
[Environment]::SetEnvironmentVariable('NEGATIVEZONE_BACKUP_INCLUDE_SAVES', '1', 'User')
```

Settings take effect the next time Prism launches.

### Restoring from a backup

1. Close Prism.
2. Open `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\`
   in File Explorer.
3. Pick the snapshot you want (folders are named `yyyyMMdd-HHmmss`).
4. Copy the files/directories you want to restore back into
   `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.minecraft\`,
   replacing the current ones.
5. Re-open Prism and launch.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `You are not white-listed on this server` | Your UUID isn't on the allowlist yet. DM the admin with username + UUID. |
| `This server has mods that require Forge to be installed on the client` | You launched the vanilla Minecraft launcher instead of the Prism C2E2 instance. Launch from Prism. |
| `Connection timed out` | Server may be down or restarting. Wait 2 min and retry. |
| `Outdated client` / `Outdated server` | Right-click your Prism instance → **Edit** → **Version** → update to the latest C2E2 release. |
| Setup says "Your PC has X GB of RAM... will not run reliably" | C2E2 needs 8 GB total system RAM minimum. There's no workaround at this size — either upgrade your RAM or play a lighter modpack. |
| Game crashes on launch | Most common cause is **too much** memory allocated, not too little. Prism Settings → Java → Maximum memory: try **4096** first (especially on 8 GB systems). If that fails, confirm Java 17 is selected and send the crash log to the admin. |
| Super low FPS | In-game: **Options → Video Settings → Render Distance: 8**, **Graphics: Fast**. |
| `Failed to verify username` / `Bad login` | Prism → top-right account dropdown → **Manage Accounts** → click your account → **Refresh**. |
| `winget` errors during setup script | Update Windows (Settings → Windows Update), or install [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1) from the Store. |
| Java still says version 8 after install | Restart your PC — Windows sometimes doesn't pick up the new PATH until reboot. |
| Prism shows `PreLaunchCommand failed` / instance won't launch | The auto-update step failed and refused to start the game. Open `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\update.log` for the actual error. Most common cause is a corrupted download — re-launch and the next attempt usually succeeds. As a one-time escape hatch you can uncheck **Custom commands** in the instance's **Edit → Settings → Custom commands** tab to launch without the update step, but the server may kick you if your mods are out of date. |
| Custom mods or config tweaks reverted after launch | The auto-update step replaces anything that isn't in the official manifest. This is **expected** — the server kicks players with mismatched mods anyway. To test custom mods locally without them being overwritten, uncheck **Custom commands** in the instance's **Edit → Settings → Custom commands** tab (you won't be able to connect to the live server while it's unchecked). |
| Prism takes a long time to show "Stopped" after quitting the game | A backup snapshot is in progress (runs at most every 3 days; takes ~10–60 s depending on how much explored map data you have). Check `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backup.log` to confirm. If you want to disable backups, set `NEGATIVEZONE_BACKUP_DISABLE=1` in your user environment (see [Periodic backups](#periodic-backups)). |
| Lost a waypoint / world / setting after a recent modpack update | Restore from a snapshot in `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\` — see [Restoring from a backup](#restoring-from-a-backup) for the runbook. The auto-update step takes a snapshot just before every update, so there should be a fresh one. |

Still stuck? DM the admin with the exact error (screenshot is best), your Minecraft
username, and what step you got stuck on.

---

## Quick reference

| | |
|---|---|
| **Server address** | `mc.negativezone.cc` |
| **Setup script** | `irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 \| iex` |
| **Minecraft version** | 1.20.1 |
| **Modpack** | [Craft to Exile 2](https://www.curseforge.com/minecraft/modpacks/craft-to-exile-2) |
| **Mod loader** | Forge |
| **Java version** | 17 (Eclipse Temurin) |
| **Launcher** | [Prism Launcher](https://prismlauncher.org/) |
| **UUID lookup** | [minecraftuuid.com](https://minecraftuuid.com/) |
