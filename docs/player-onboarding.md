---
layout: default
title: Player Onboarding
nav_order: 2
---

# Player Onboarding Guide
{: .no_toc }

Never modded Minecraft before? **You're in the right place.** This guide walks
you through every click, from buying Minecraft to joining the server. No prior
modding experience needed.

If you already play Minecraft Java Edition with mods, you can skim — the only
NegativeZone-specific bits are **Step 1 (whitelist)** and **Step 4 (server address)**.

<details markdown="1">
<summary>Table of contents</summary>

1. TOC
{:toc}
</details>

---

## What you'll need

- A Windows PC (this guide is Windows-specific; macOS/Linux steps differ slightly)
- A **paid Minecraft Java Edition** account (the **Bedrock** version sold on Xbox / Microsoft Store / mobile **does not work** — it must be Java Edition)
- About **30–45 minutes** for the full setup
- ~10 GB of free disk space

> **Don't have Minecraft Java yet?** Buy it from
> [minecraft.net/store/minecraft-java-edition](https://www.minecraft.net/en-us/store/minecraft-java-edition)
> — make sure the listing says **"Minecraft: Java Edition"**.

---

## Step 1 — Get your username and UUID for the whitelist

Our server is **whitelist-only** to keep griefers out. Before you can join,
an admin (Cam) needs to add you. To do that, they need two things:

1. Your **Minecraft Java username** (the name shown above your character in-game)
2. Your **UUID** — a unique ID Minecraft uses internally

### How to find them

1. Go to **[namemc.com](https://namemc.com/)** in your web browser
2. Type your Minecraft Java username in the search bar at the top and press **Enter**
3. On the result page, look for the line that says **"UUID"** — it'll look something like:
   `a30918db-b4fe-4659-9575-ebc8c19640b8`
4. Copy your **username** and the **UUID** (the one **with dashes**)

![NameMC username and UUID lookup](assets/images/namemc-lookup.png)

### Send them to the admin

Message Cam on Discord (or wherever you usually chat) with:

```
Username: <your-username>
UUID: <your-uuid>
```

You'll get a confirmation when you've been added. Until then, the server will
reject your connection with "You are not white-listed on this server".

---

## Step 2 — Install Java 17

The modpack runs on Minecraft 1.20.1, which requires **Java 17**.
**Other Java versions will not work** — not Java 8, not Java 21. Specifically 17.

### Check if you already have it

1. Press the **Windows key**, type `powershell`, and press **Enter**
2. In the blue window that appears, type:
   ```powershell
   java -version
   ```
   and press **Enter**
3. If the first line says something like `openjdk version "17.x.x"` **or**
   `java version "17.x.x"`, you're done — skip to Step 3.

Anything else (no Java found, or a different version like 8 or 21) means you
need to install Java 17.

### Install Java 17

We'll use **winget** — Windows' built-in package manager. It comes pre-installed
on Windows 10 (recent updates) and Windows 11, so you don't need to download it.

1. Press the **Windows key**, type `powershell`, and press **Enter**
2. In the blue window, copy-paste this command and press **Enter**:
   ```powershell
   winget install --id EclipseAdoptium.Temurin.17.JDK -e --source winget
   ```
3. If Windows asks for permission ("Do you agree to the source agreements?"), type **Y** and press **Enter**
4. Wait for the install to finish — you'll see a progress bar, then "Successfully installed"

That's it. winget installs Temurin 17, sets `JAVA_HOME` automatically, and adds Java to your PATH.

> **`winget` not found?** You're on an older Windows build. Either update Windows
> via Settings → Windows Update, or install the
> [App Installer from the Microsoft Store](https://apps.microsoft.com/detail/9NBLGGH4NNS1)
> which includes winget.

### Verify

Close any open PowerShell windows, open a new one, and run `java -version` again.
You should now see Java 17. If you still don't, restart your PC and try once more.

---

## Step 3 — Install Prism Launcher and the Craft to Exile 2 modpack

Prism Launcher is a free, open-source Minecraft launcher that handles modpacks
for you. We use it instead of the official Minecraft Launcher because it
downloads modpacks from CurseForge in one click.

### Install Prism Launcher

1. Go to **[prismlauncher.org/download/windows](https://prismlauncher.org/download/windows/)**
2. Download the **Windows Installer (MSVC) — x86_64** `.exe`
3. Run the installer and click through with the defaults
4. Launch **Prism Launcher** from your Start menu

### Add your Microsoft account

The first time you open Prism it'll walk you through adding an account.

1. When prompted, click **Microsoft** as the account type
2. Click **Open the page and copy the code** — your browser will open
3. Paste the code, sign in with the same Microsoft account that owns Minecraft Java
4. Once it says "You have signed in", switch back to Prism

![Prism Launcher Microsoft account setup](assets/images/prism-microsoft-login.png)

### Tell Prism about Java 17

1. In the top-right corner of Prism, click **Settings**
2. Click the **Java** tab on the left
3. Click **Auto-detect...** under "Java Installation"
4. Select the **Java 17** entry from the list (it'll say something like
   `JavaSE 17.x.x` with a path containing `Eclipse Adoptium`) → **OK**
5. Under **Memory**, set **Maximum memory allocation** to **`8192`** (= 8 GB)
   - If your PC has only 8 GB of RAM total, use **`6144`** instead
   - If you have 32 GB+, you can go up to **`12288`**

![Prism Java settings with Java 17 detected](assets/images/prism-java-settings.png)
![Prism memory allocation set to 8192 MiB](assets/images/prism-memory-settings.png)

Click **OK** to save.

### Add the Craft to Exile 2 modpack

1. Back at Prism's main window, click **Add Instance** in the top-left
2. In the dialog, click **CurseForge** in the left sidebar
3. In the search bar, type **`Craft to Exile 2`** and press **Enter**
4. Click the result titled **"Craft to Exile 2"** (the icon is a brown leather book)
5. In the **Version** dropdown on the right, leave it at the **latest version**
   (it auto-selects the newest release)
6. Click **OK** at the bottom

![Prism Add Instance button](assets/images/prism-add-instance.png)
![Prism CurseForge tab searching for Craft to Exile 2](assets/images/prism-curseforge-search.png)

Prism will download Forge + all the mods + configs. **This takes 5–15 minutes**
depending on your internet — there are hundreds of mods. Let it run.

When the download finishes, you'll see a **Craft to Exile 2** entry in your
instance list.

> **⚠️ Do NOT install extra mods.** The server checks that your mod list
> matches the modpack exactly. Adding random mods will get you kicked.

---

## Step 4 — Connect to the server

1. In Prism's main window, click your **Craft to Exile 2** instance
2. Click **Launch** in the right panel

   ![Prism launch button](assets/images/prism-launch.png)

3. The Minecraft launcher window will show download progress; once Minecraft
   opens, click **Multiplayer** from the title screen
4. Click **Add Server**
5. Fill in:
   - **Server Name:** `NegativeZone` (or anything you like)
   - **Server Address:** `mc.negativezone.cc`
6. Click **Done**

   ![Add server dialog](assets/images/mc-multiplayer-add.png)

7. You'll see the NegativeZone server in the list with a **green ping bar**
   if it's online. Double-click it to join.

   ![Server list showing NegativeZone](assets/images/mc-join.png)

**That's it!** You'll be automatically connected straight into Craft to Exile 2.

> **What happens behind the scenes:** when you join `mc.negativezone.cc`,
> the server automatically forwards you into the Craft to Exile 2 world.
> No commands needed. If C2E2 is restarting or down for maintenance, you'll
> land in a small "lobby" world instead — wait a minute and try `/server c2e2`
> to retry.

---

## Troubleshooting

| Problem | What to do |
|---------|------------|
| `You are not white-listed on this server` | Your UUID isn't on the whitelist yet. DM Cam with your username + UUID. |
| `This server has mods that require Forge to be installed on the client` | You connected with the vanilla Minecraft launcher instead of the Prism C2E2 instance. Launch the **Craft to Exile 2** instance from Prism (Step 4). |
| `Connection timed out` / `Failed to connect` | Server may be down or restarting. Wait 2 minutes and retry. If it persists, ping Cam. |
| `Outdated client` / `Outdated server` | Your modpack version doesn't match the server. In Prism, right-click your C2E2 instance → **Edit** → **Version** → update to the latest. |
| Game crashes on launch | Probably out of memory. Go to Prism Settings → Java → bump Maximum memory up (try 8192 or 10240). |
| Super low FPS in-game | In Minecraft: **Options → Video Settings → Render Distance: 8**, **Graphics: Fast**. C2E2 is heavy — these help a lot. |
| `Failed to verify username` / `Bad login` | Your Microsoft session in Prism expired. Prism → top-right account dropdown → **Manage Accounts** → click your account → **Refresh**. |
| Java still says version 8 after installing 17 | Restart your PC. Windows sometimes doesn't pick up the new PATH until reboot. |

Still stuck? Ping Cam on Discord with:
- The exact error message (screenshot is best)
- Your Minecraft username
- What step you got stuck on

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
| **Minecraft version** | 1.20.1 |
| **Modpack** | [Craft to Exile 2](https://www.curseforge.com/minecraft/modpacks/craft-to-exile-2) |
| **Mod loader** | Forge |
| **Java version** | 17 (Eclipse Temurin) |
| **Launcher** | [Prism Launcher](https://prismlauncher.org/) |
| **UUID lookup** | [namemc.com](https://namemc.com/) |
