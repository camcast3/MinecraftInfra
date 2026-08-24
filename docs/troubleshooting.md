---
layout: default
title: Troubleshooting
nav_order: 6
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
| Game thrashes / crashes on a low-RAM PC | The instance ships pinned to an 8 GB allocation. C2E2 needs ~8 GB total system RAM to run well; on an 8 GB-total PC, lower Prism → **Settings → Java → Memory** to **4096** so Windows isn't starved. |
| Install printed an unexpected error and bailed | Re-run the one-liner — most failures are transient (network blip during the modpack zip download, winget mid-update). If it keeps failing, screenshot the error and DM the admin. |

---

## Connecting to the server

| Problem | Fix |
|---|---|
| `You are not white-listed on this server` | Your UUID isn't on the allowlist yet. DM the admin with username + UUID. |
| `This server has mods that require Forge to be installed on the client` | You launched the vanilla Minecraft launcher instead of the Prism C2E2 instance. Launch from Prism. |
| `Connection timed out` | Server may be down or restarting. Wait 2 min and retry. |
| `Outdated client` / `Outdated server` at the FML handshake | Your modpack version doesn't match the server's. See [Updates]({% link updates.md %}) — usually fixed by double-clicking the **Update Craft to Exile 2** launcher (or running `nz update`). |
| Server name in the server list shows a different version than your instance | New modpack version is out and your client hasn't picked it up. Double-click the **Update Craft to Exile 2** launcher — see [Updates]({% link updates.md %}). |
| Connected but instantly disconnected | Usually a mod-list mismatch. Run `nz update` (the Update launcher). If that doesn't help, re-run the install one-liner — it does a clean reinstall preserving your state. |

---

## Launching the game

| Problem | Fix |
|---|---|
| Prism shows `MODPACK VERSION MISMATCH` and refuses to launch | This is the launch-time version check (`nz check`). Close Prism and double-click the **Update Craft to Exile 2** launcher — full walk-through in [Updates]({% link updates.md %}). |
| Prelaunch printed `Could not fetch latest version (...); allowing launch.` | GitHub raw or your internet is briefly unreachable — the check fails open and lets you launch with whatever you have installed. Server will kick you at FML handshake if your mods don't match the current pinned version. Re-try later. |
| Prism shows `PreLaunchCommand failed` and won't launch | The version-check hook crashed. Re-run the install one-liner — it reinstalls the hooks and `nz.exe`. If still broken, uncheck **Custom commands** in the instance's **Edit → Settings → Custom commands** tab as a temporary workaround (server may kick you if mods are out of date), then re-run the installer. |
| Game crashes on launch | Most common cause is **too much** memory allocated, not too little. Prism Settings → Java → Maximum memory: try **4096** first (especially on 8 GB systems). If that fails, confirm Java 17 is selected and send the crash log to the admin. |
| Custom mods or pack-owned config tweaks reverted after update | Updates delta-sync tracked modpack files with packwiz so your client matches the server. Personal state and preserve-list configs should stay in place. If you want to test custom mods locally, uncheck **Custom commands** in the instance's **Edit → Settings → Custom commands** tab (you won't be able to connect to the live server while it's unchecked). |

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
| Prism takes a long time to show "Stopped" after quitting the game | A backup snapshot is in progress (runs at most every 3 days; takes ~10–60 s depending on explored-map size). Check `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\nz.log` to confirm. To disable, see [Backups → Tuning or disabling]({% link backups.md %}#tuning-or-disabling). |
| Lost a waypoint / world / setting after a recent update | Restore from a snapshot under `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\backups\` — see [Backups → Restoring user state from a snapshot]({% link backups.md %}#restoring-user-state-from-a-snapshot). The update step forces a snapshot just before every upgrade, so there's always a fresh restore point. |
| Empty / 0-byte snapshots in `.negativezone\backups\<ts>\` | Should be fixed in v0.4.2+; if you see one in a freshly created snapshot, run `nz support` and DM the admin the resulting zip (it includes `nz.log`). |
| Old rollback copies are using space | `Craft to Exile 2.bak` and `Craft to Exile 2 (old)` are recreated by the next setup upgrade. Transaction backups under `instances\.negativezone-backups\` are separate; send `nz support` output to the admin before deleting those. |

---

## Collecting logs for the admin

Every `nz` command writes a full-detail record to **`nz.log`** inside the
instance's `.negativezone\` folder
(`%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone\nz.log`).
First-install logs (before the instance exists) land in the global fallback at
`%LOCALAPPDATA%\NegativeZone\nz.log`.

| Need | Do this |
|---|---|
| Send everything the admin needs in one file | Double-click the **Update Craft to Exile 2** launcher's folder and run `nz support` (or `"…\.negativezone\nz.exe" support`). It writes `nz-support-<timestamp>.zip` to your Desktop — DM that to the admin. |
| See more detail on the console while a command runs | Add `--verbose` (e.g. `nz update --verbose`). `nz.log` always contains the full detail regardless. |
| Quieter console (errors only) | Add `--quiet` (e.g. `nz check --quiet`). |
