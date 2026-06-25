---
layout: default
title: Troubleshooting
nav_order: 5
---

# Troubleshooting
{: .no_toc }

Common issues and fixes. If you don't see your problem here, DM the admin
with a screenshot of the exact error, your Minecraft username, and what
step you got stuck on.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

---

## Install / setup

| Problem | Fix |
|---|---|
| `winget` not found | You're on an older Windows build. Install [App Installer](https://apps.microsoft.com/detail/9NBLGGH4NNS1) from the Microsoft Store, which includes winget. |
| Java still says version 8 after install | Restart your PC — Windows sometimes doesn't pick up the new PATH until reboot. |
| Setup says "Your PC has X GB of RAM... will not run reliably" | C2E2 needs 8 GB total system RAM minimum. There's no workaround at this size — either upgrade your RAM or play a lighter modpack. |
| Setup printed an unexpected error and bailed | Re-run the one-liner — most failures are transient (network blip during the modpack zip download, winget mid-update). If it keeps failing, screenshot the error and DM the admin. |

---

## Connecting to the server

| Problem | Fix |
|---|---|
| `You are not white-listed on this server` | Your UUID isn't on the allowlist yet. DM the admin with username + UUID. |
| `This server has mods that require Forge to be installed on the client` | You launched the vanilla Minecraft launcher instead of the Prism C2E2 instance. Launch from Prism. |
| `Connection timed out` | Server may be down or restarting. Wait 2 min and retry. |
| `Outdated client` / `Outdated server` at the FML handshake | Your modpack version doesn't match the server's. See [Updates]({% link updates.md %}) — usually fixed by running the update one-liner from a new PowerShell window. |
| Server name in the server list shows a different version than your instance | New modpack version is out and your client hasn't picked it up. Run the update one-liner — see [Updates]({% link updates.md %}). |
| Connected but instantly disconnected | Usually a mod-list mismatch. Re-run the update one-liner. If that doesn't help, re-run the setup one-liner — it does a clean reinstall preserving your state. |

---

## Launching the game

| Problem | Fix |
|---|---|
| Prism shows `MODPACK VERSION MISMATCH` and refuses to launch | This is the launch-time version check. Run the update one-liner from a new PowerShell window — full walk-through in [Updates]({% link updates.md %}). |
| Prelaunch printed `Could not fetch latest version pointer (...); allowing launch.` | GitHub raw or your internet is briefly unreachable — the check fails open and lets you launch with whatever you have installed. Server will kick you at FML handshake if your mods don't match the current pinned version. Re-try later. |
| Prism shows `PreLaunchCommand failed` and won't launch | The version-check hook crashed. Re-run the setup one-liner — it reinstalls the hook scripts. If still broken, uncheck **Custom commands** in the instance's **Edit → Settings → Custom commands** tab as a temporary workaround (server may kick you if mods are out of date), then re-run setup. |
| Game crashes on launch | Most common cause is **too much** memory allocated, not too little. Prism Settings → Java → Maximum memory: try **4096** first (especially on 8 GB systems). If that fails, confirm Java 17 is selected and send the crash log to the admin. |
| Custom mods or config tweaks reverted after update | The update step replaces anything not in the pack-author preserve list. If a config you'd tuned didn't carry over, copy it back from the **`Craft to Exile 2 (old)`** instance — see [Updates → Restoring settings from your old instance]({% link updates.md %}#restoring-settings-from-your-old-instance-manual). If you want to test custom mods locally, uncheck **Custom commands** in the instance's **Edit → Settings → Custom commands** tab (you won't be able to connect to the live server while it's unchecked). |

---

## Performance

| Problem | Fix |
|---|---|
| Super low FPS | In-game: **Options → Video Settings → Render Distance: 8**, **Graphics: Fast**. |
| Frequent stutters / freezes | Open Task Manager while playing — if RAM is maxed, lower Prism's Memory allocation by 2 GB and restart. |
| Long stalls on world entry | First-time chunk loading. Improves dramatically once the area has been explored once (Xaero map cache warms up). |

---

## Backups

| Problem | Fix |
|---|---|
| Prism takes a long time to show "Stopped" after quitting the game | A backup snapshot is in progress (runs at most every 3 days; takes ~10–60 s depending on explored-map size). Check `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backup.log` to confirm. To disable, see [Backups → Tuning or disabling]({% link backups.md %}#tuning-or-disabling). |
| Lost a waypoint / world / setting after a recent update | Two recovery sources: (a) the **`Craft to Exile 2 (old)`** instance under the **Backup** group — copy from its `.minecraft\` folder, see [Updates → Restoring settings from your old instance]({% link updates.md %}#restoring-settings-from-your-old-instance-manual); or (b) a periodic snapshot under `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\` — see [Backups → Restoring user state from a snapshot]({% link backups.md %}#restoring-user-state-from-a-snapshot). The update step forces a snapshot just before every upgrade, so there's always a fresh restore point. |
| Empty / 0-byte snapshots in `.negativezone\backups\<ts>\` | Should be fixed in v0.4.2+; if you see one in a freshly created snapshot, screenshot `backup.log` and DM the admin. |
| Backup group in Prism has an old version I want to delete | Right-click → **Delete instance** in Prism. The next upgrade will create a fresh Backup. |
