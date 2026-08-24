---
layout: default
title: Get started
nav_order: 2
redirect_from:
  - /player-onboarding/
  - /player-onboarding.html
---

# Get started
{: .no_toc }

Two install paths: a **one-line automated setup** (recommended) or
**manual step-by-step** if you'd rather see what's happening.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

> **Already playing on an older client?** Run the **Path A** one-liner once.
> It preserves your worlds, waypoints, and tuned settings while repairing or
> replacing any retired PowerShell hooks with nz.

---

## What you'll need

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

> The published modpack instance ships **pinned to an 8 GB allocation** with
> automatic Java detection, so you normally don't need to touch Prism's Java or
> memory settings. On a PC with only 8 GB total RAM, lower it to **4096** (4 GB)
> in Prism → **Settings → Java → Memory** so Windows isn't starved.

---

## Path A — Automated setup (recommended)

A single PowerShell command installs **Java 17**, **Prism Launcher**, and the
**Craft to Exile 2 modpack** (pulled directly from our Azure storage — much
faster than CurseForge), then wires Prism's launch-time version check and
auto-backup hooks and drops an **Update Craft to Exile 2** launcher on your
Desktop. ~3 minutes.

### Run it

1. Press the **Windows key**, type `powershell`, press **Enter**
2. Copy-paste this command and press **Enter**:

   ```powershell
   irm https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/install.ps1 | iex
   ```

3. Approve any winget prompts (press **Y** + Enter if asked)
4. Wait ~2–3 minutes while it installs Java, Prism, and the modpack

> **Cautious? Verify before running.** `nz-latest` is the gated production
> bootstrap. Its `nz-release.json` points to an immutable `nz-v<commit>` release,
> and `install.ps1` verifies the downloaded `nz.exe` size and SHA-256 before
> replacing your installed copy. `nz setup` separately verifies the modpack
> zip SHA-256 before installation.

### After the script finishes

1. **DM the admin your Minecraft Java username** so they can allowlist you. Wait for confirmation. (If they ask for your UUID too, look it up at [minecraftuuid.com](https://minecraftuuid.com/).)
2. Open **Prism Launcher** from the Start menu
3. **Sign in with your Microsoft account** (the one that owns Minecraft Java)
4. Launch the **Craft to Exile 2** instance (already installed by the script)
5. **Multiplayer → Add Server**, server address: `mc.negativezone.cc`
6. Join — you'll be auto-connected straight into Craft to Exile 2.

That's it. The remaining sections below are only needed if the automated
script didn't work or you want manual control.

**Next:** see [Updates]({% link updates.md %}) for how first install uses the
zip and later updates use packwiz delta-sync, and [Backups]({% link backups.md %})
for how your personal state is protected.

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

> **Heads up — manual installs don't get the launch-time version check.**
> Path B leaves you on a vanilla Prism instance with no `nz check` (version
> gate) or `nz backup` (auto-snapshot) hooks installed. You'll still see the server's MOTD update
> in your server list when a new version ships (that's your cue to upgrade),
> but you won't get the hard launch-time block or the automatic 3-day
> snapshots. To enable those, re-run the Path A one-liner once after Path B —
> it preserves your existing instance and just bolts the hooks on.
