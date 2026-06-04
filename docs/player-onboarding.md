---
layout: default
title: Player Onboarding
nav_order: 2
---

# Player Onboarding Guide

Welcome to the NegativeZone Minecraft server! This guide walks you through
everything you need to get connected and playing on Craft to Exile 2.

---

## 1. Get Your Mojang/Microsoft Account Name and UUID

The server is whitelist-only. Before you can join, an admin needs your
**Minecraft Java Edition username** and **UUID**.

### Find your username

Your username is the one shown in the Minecraft launcher (Java Edition).
If you haven't purchased Minecraft Java Edition yet, you'll need to buy it
from [minecraft.net](https://www.minecraft.net/).

### Find your UUID

1. Go to [mcuuid.net](https://mcuuid.net/)
2. Enter your Minecraft username and click **Submit**
3. Copy the **Full UUID** (the one with dashes, e.g. `a30918db-b4fe-4659-9575-ebc8c19640b8`)

Send both your **username** and **UUID** to the server admin so they can add
you to the whitelist.

---

## 2. Install Java 17 (Windows)

Craft to Exile 2 runs on Minecraft 1.20.1 which requires **Java 17**.

### Check if Java 17 is already installed

Open PowerShell or Command Prompt and run:

```powershell
java -version
```

If you see output like `openjdk version "17.x.x"` or higher, you're good —
skip to step 3.

### Install Java 17

1. Download **Eclipse Temurin 17 (LTS)** from
   [adoptium.net](https://adoptium.net/temurin/releases/?version=17&os=windows&arch=x64&package=jdk)
2. Choose the **Windows x64 `.msi` installer**
3. Run the installer — accept defaults, but make sure **"Set JAVA_HOME variable"**
   is checked
4. Restart your terminal, then verify with `java -version`

> **Tip:** Prism Launcher can auto-detect Java installations. If you install
> Temurin to the default path, Prism will find it automatically.

---

## 3. Set Up Prism Launcher with Craft to Exile 2

[Prism Launcher](https://prismlauncher.org/) is a free, open-source Minecraft
launcher that makes managing modpacks easy.

### Install Prism Launcher

1. Download from [prismlauncher.org/download](https://prismlauncher.org/download/)
2. Run the installer (Windows x64)
3. On first launch, Prism will ask you to sign in with your **Microsoft account**
   (the one linked to your Minecraft Java Edition license)

### Configure Java in Prism

1. Go to **Settings → Java**
2. Click **Auto-detect** — select the Java 17 installation
3. Set **Maximum memory allocation** to at least **6144 MiB** (6 GB)
   — C2E2 is a heavy modpack; 8192 MiB (8 GB) is recommended if you have 16+ GB RAM

### Install the Craft to Exile 2 modpack

1. Click **Add Instance** (top-left)
2. Select **CurseForge** in the left sidebar
3. Search for **"Craft to Exile 2"**
4. Select the pack and choose the **latest version for Minecraft 1.20.1**
5. Click **OK** — Prism will download Forge + all mods automatically

> **Important:** Do NOT install extra client mods unless you know they're
> compatible. The server will reject connections from clients with mismatched mods.

---

## 4. Connect to the Server

### Add the server

1. Launch the **Craft to Exile 2** instance in Prism Launcher
2. Once Minecraft loads, go to **Multiplayer → Add Server**
3. Enter:
   - **Server Name:** NegativeZone (or whatever you like)
   - **Server Address:** `mc.negativezone.cc`
4. Click **Done**

### Join and play

1. Select the server and click **Join Server**
2. You'll land in the **lobby** first — this is a lightweight waiting area
3. You'll be automatically forwarded to the **Craft to Exile 2** server

### Troubleshooting

| Problem | Solution |
|---------|----------|
| "You are not white-listed on this server" | Ask the admin to add your UUID to the whitelist |
| "This server has mods that require Forge to be installed on the client" | You connected with vanilla Minecraft. Launch the **Craft to Exile 2** instance from Prism Launcher instead |
| Connection timed out | Check that you're using `mc.negativezone.cc` with no port number |
| "Incompatible Forge version" | Make sure your C2E2 modpack is the latest 1.20.1 version — update in Prism if needed |
| Extreme lag / low FPS | Allocate more RAM (8 GB+), lower render distance in video settings, ensure you're using Java 17 (not 8 or 21) |

---

## System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| RAM | 12 GB total (6 GB to MC) | 16+ GB total (8 GB to MC) |
| CPU | 4 cores | 6+ cores |
| Storage | 10 GB free | SSD with 20+ GB free |
| Java | 17 (required) | 17 (Temurin LTS) |
| Internet | Broadband | Low-latency connection |

---

## Quick Reference

| Item | Value |
|------|-------|
| Server address | `mc.negativezone.cc` |
| Minecraft version | 1.20.1 |
| Modpack | Craft to Exile 2 (CurseForge) |
| Mod loader | Forge |
| Java version | 17 |
| Launcher | Prism Launcher (recommended) |
| Whitelist UUID lookup | [mcuuid.net](https://mcuuid.net/) |
