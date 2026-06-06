---
layout: default
title: Player Onboarding
nav_order: 2
---

# Player Onboarding Guide
{: .no_toc }

Get connected to **NegativeZone** in two ways: a one-line automated setup (~3 min), or manual step-by-step if you'd rather see what's happening.

{: .highlight-title }
> Quick start
>
> Open **PowerShell** and paste:
>
> ```powershell
> irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 | iex
> ```
>
> Then DM the admin the username + UUID that the script copies to your clipboard. Full instructions are below.

---

<details markdown="1" open>
<summary><strong>Table of contents</strong></summary>

* TOC
{:toc}
</details>

---

## Before you start

You need all three of these:

| ✅ | What | Why |
|---|------|-----|
| **Windows 10 or 11** | Setup script is PowerShell + winget | Other OSes work, but Path B is the only path |
| **Paid Minecraft Java Edition** | The server is Java-only | Bedrock from Xbox / MS Store / mobile **does not work** |
| **~10 GB free disk space** | Modpack + Java + Prism | Mostly the modpack |

{: .note }
Don't own Minecraft Java yet? Buy it at [minecraft.net/store/minecraft-java-edition](https://www.minecraft.net/en-us/store/minecraft-java-edition). After buying, make sure you can log into it once in the official launcher before continuing.

---

## Path A — Automated setup
{: .d-inline-block }

Recommended
{: .label .label-green }
~3 min
{: .label .label-blue }

One PowerShell command installs **Java 17**, **Prism Launcher**, and the **Craft to Exile 2 modpack** (pulled from our Azure storage — much faster than CurseForge), looks up your **UUID**, and copies the allowlist info to your clipboard.

### 1. Run the installer

1. Press the **Windows key**, type `powershell`, press **Enter**
2. Paste this and press **Enter**:

   ```powershell
   irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 | iex
   ```

3. Approve any **winget** prompts (press **Y** + Enter if asked)
4. When prompted, type your **Minecraft Java username** and press **Enter**
5. Wait for `Username: ... / UUID: ...` to land on your clipboard

### 2. Get allowlisted

**DM the admin** and paste with **Ctrl+V**. Wait for confirmation you're allowlisted.

### 3. Launch and join

1. Open **Prism Launcher** from the Start menu
2. **Sign in with your Microsoft account** (the one that owns Minecraft Java)
3. Launch the **Craft to Exile 2** instance — already installed by the script
4. **Multiplayer → Add Server**, address: `mc.negativezone.cc`
5. Join — you'll be auto-connected straight into Craft to Exile 2

That's it. The rest of this page is only needed if the script didn't work, or you want manual control.

{: .important-title }
> Cautious about `irm ... | iex`?
>
> The script ships as a GitHub Release asset with a published **SHA-256** hash, and the modpack zip is hash-verified before extraction. See [Releases](https://github.com/camcast3/MinecraftInfra/releases?q=setup-v) — each one includes a copy-paste verification one-liner that refuses to run on tamper.

---

## Path B — Manual setup
{: .d-inline-block }

Advanced
{: .label .label-yellow }
~15 min
{: .label .label-blue }

Use this if Path A errored out, or if you'd rather do every step yourself.

### Step 1 — Get your username and UUID

The server is **allowlist-only**. The admin needs your Minecraft Java **username** and **UUID** before you can join.

1. Open [**minecraftuuid.com**](https://minecraftuuid.com/)
2. Type your username, press **Enter**
3. Copy your **username** and the **Full UUID** (with dashes — e.g. `a30918db-b4fe-4659-9575-ebc8c19640b8`)

DM the admin:

```
Username: <your-username>
UUID: <your-uuid>
```

Wait for confirmation you've been added.

### Step 2 — Install Java 17

Minecraft 1.20.1 requires **Java 17** specifically — not 8, not 21.

**Check first:**

```powershell
java -version
```

If it prints `version "17.x.x"`, skip to Step 3. Otherwise install via winget:

```powershell
winget install --id EclipseAdoptium.Temurin.17.JDK -e --source winget
```

Approve any prompts. winget auto-configures `JAVA_HOME` and PATH. Close and reopen PowerShell, then verify with `java -version`.

{: .warning }
> `winget` not found? You're on an older Windows build. Install [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1) from the Microsoft Store, which includes winget.

### Step 3 — Install Prism Launcher

Prism Launcher is a free, open-source Minecraft launcher that handles modpacks in one click.

```powershell
winget install --id PrismLauncher.PrismLauncher -e --source winget
```

Or grab the installer from [prismlauncher.org/download/windows](https://prismlauncher.org/download/windows/).

### Step 4 — Configure Prism

1. Open **Prism Launcher** from your Start menu
2. **Sign in with your Microsoft account** — click **Microsoft**, then **Open the page and copy the code**, paste it in your browser, and sign in with the account that owns Minecraft Java
3. **Settings** (top-right) → **Java** tab:
   - Click **Auto-detect...** → select the **Java 17** entry → **OK**
   - Under **Memory**, set **Maximum memory allocation** to **`8192`** (= 8 GB)
     - 8 GB RAM total → use `6144` instead
     - 32+ GB RAM → can go up to `12288`
   - Click **OK** to save

### Step 5 — Install the Craft to Exile 2 modpack

1. Click **Add Instance** (top-left)
2. Click **CurseForge** in the left sidebar
3. Search **`Craft to Exile 2`**, press Enter
4. Click the result (brown leather book icon) → leave **Version** at latest → **OK**

Prism downloads Forge + all the mods (5–15 min depending on your internet).

{: .warning-title }
> Do **not** install extra mods
>
> The server checks that your mod list matches the modpack exactly. Adding random mods will get you kicked.

### Step 6 — Connect to the server

1. Select the **Craft to Exile 2** instance → **Launch**
2. Once Minecraft loads: **Multiplayer** → **Add Server**
3. Fill in:
   - **Server Name:** `NegativeZone`
   - **Server Address:** `mc.negativezone.cc`
4. **Done** → double-click the server to join

You'll be **automatically forwarded straight into Craft to Exile 2**. If C2E2 is restarting, you'll get a "Server unavailable" message — wait a minute and try again.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `You are not white-listed on this server` | Your UUID isn't on the allowlist yet. DM the admin with username + UUID. |
| `This server has mods that require Forge to be installed on the client` | You launched the vanilla launcher. Launch from Prism. |
| `Connection timed out` | Server may be restarting. Wait 2 min, retry. |
| `Outdated client` / `Outdated server` | Right-click your Prism instance → **Edit** → **Version** → update to latest. |
| Game crashes on launch | Out of memory. Prism Settings → Java → bump Maximum memory (8192 or 10240). |
| Super low FPS | In-game: **Options → Video Settings → Render Distance: 8**, **Graphics: Fast**. |
| `Failed to verify username` / `Bad login` | Prism → account dropdown (top-right) → **Manage Accounts** → click your account → **Refresh**. |
| `winget` errors during setup script | Update Windows (Settings → Windows Update), or install [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1). |
| Java still says version 8 after install | Restart your PC — Windows sometimes won't pick up the new PATH until reboot. |

Still stuck? DM the admin with the **exact error** (screenshot is best), your **Minecraft username**, and **which step** you got stuck on.

---

## System requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| RAM (total) | 12 GB | 16+ GB |
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
| **Minecraft version** | 1.20.1 |
| **Mod loader** | Forge |
| **Modpack** | [Craft to Exile 2](https://www.curseforge.com/minecraft/modpacks/craft-to-exile-2) |
| **Launcher** | [Prism Launcher](https://prismlauncher.org/) |
| **Java version** | 17 (Eclipse Temurin) |
| **UUID lookup** | [minecraftuuid.com](https://minecraftuuid.com/) |
| **Setup script** | `irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 \| iex` |
