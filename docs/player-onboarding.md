---
layout: default
title: Player Onboarding
nav_order: 2
---

# Player Onboarding Guide
{: .no_toc }

Two paths to get connected: a **one-line automated setup** (recommended) or
**manual step-by-step** if you'd rather see what's happening.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

---

## What you'll need before starting

- A Windows 10/11 PC
- A **paid Minecraft Java Edition** account (Bedrock from Xbox / Microsoft Store / mobile **does not work**)
- ~10 GB free disk space

> **Don't have Minecraft Java yet?** Get it from
> [minecraft.net/store/minecraft-java-edition](https://www.minecraft.net/en-us/store/minecraft-java-edition).

---

## Path A — Automated setup (recommended)

A single PowerShell command installs **Java 17**, **Prism Launcher**, the
**Craft to Exile 2 modpack** (pulled directly from our Azure storage — much
faster than CurseForge), looks up your **UUID**, and copies the allowlist
info to your clipboard. ~3 minutes.

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

1. **DM the admin (Cam)** on Discord — paste with **Ctrl+V** to send your username + UUID. Wait for confirmation you're allowlisted.
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

![minecraftuuid.com username lookup](assets/images/minecraftuuid-lookup.png)

DM Cam on Discord:

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

   ![Prism Microsoft login](assets/images/prism-microsoft-login.png)

3. Click **Settings** (top-right) → **Java** tab:
   - Click **Auto-detect...** → select the **Java 17** entry → **OK**
   - Under **Memory**, set **Maximum memory allocation** to **`8192`** (= 8 GB)
     - If your PC has only 8 GB RAM total, use `6144` instead
     - If you have 32+ GB RAM, you can go up to `12288`

   ![Prism Java settings](assets/images/prism-java-settings.png)

   Click **OK** to save.

### Step 5 — Install the Craft to Exile 2 modpack

1. Back at Prism's main window, click **Add Instance** (top-left)
2. Click **CurseForge** in the left sidebar
3. Search **`Craft to Exile 2`** and press Enter
4. Click the result (icon is a brown leather book) → leave **Version** at latest → **OK**

   ![Prism CurseForge search](assets/images/prism-curseforge-search.png)

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

   ![Minecraft add server](assets/images/mc-multiplayer-add.png)

You'll be **automatically forwarded straight into Craft to Exile 2**. If C2E2
is restarting, you'll get a "Server unavailable" message — wait a minute and
try again.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `You are not white-listed on this server` | Your UUID isn't on the allowlist yet. DM Cam with username + UUID. |
| `This server has mods that require Forge to be installed on the client` | You launched the vanilla Minecraft launcher instead of the Prism C2E2 instance. Launch from Prism. |
| `Connection timed out` | Server may be down or restarting. Wait 2 min and retry. |
| `Outdated client` / `Outdated server` | Right-click your Prism instance → **Edit** → **Version** → update to the latest C2E2 release. |
| Game crashes on launch | Out of memory. Prism Settings → Java → bump Maximum memory (8192 or 10240). |
| Super low FPS | In-game: **Options → Video Settings → Render Distance: 8**, **Graphics: Fast**. |
| `Failed to verify username` / `Bad login` | Prism → top-right account dropdown → **Manage Accounts** → click your account → **Refresh**. |
| `winget` errors during setup script | Update Windows (Settings → Windows Update), or install [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1) from the Store. |
| Java still says version 8 after install | Restart your PC — Windows sometimes doesn't pick up the new PATH until reboot. |

Still stuck? DM Cam with the exact error (screenshot is best), your Minecraft
username, and what step you got stuck on.

---

## System requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Windows 10 64-bit | Windows 11 |
| RAM | 12 GB total | 16+ GB |
| RAM allocated to Minecraft | 6 GB | 8 GB |
| CPU | 4 cores, 3 GHz+ | 6+ cores |
| Storage | 10 GB free | 20+ GB on SSD |
| Java | 17 (Temurin) | 17 (Temurin) |
| Internet | 5 Mbps down | 25+ Mbps down |

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
