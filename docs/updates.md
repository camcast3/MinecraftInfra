---
layout: default
title: Updates
nav_order: 4
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
- **If you don't match:** Prism shows a hard block with on-screen instructions.
  Close Prism, **double-click the `Update Craft to Exile 2` launcher** on your
  Desktop, then relaunch.
- First install still downloads one prebuilt zip from Azure Blob Storage. Updates
  now delta-sync with `packwiz-installer`, so only changed modpack files are
  downloaded.
- **If GitHub is unreachable:** the check fails open so offline play still works.

You're never auto-updated *during* launch any more — updating is a
**deliberate action** (double-click the Desktop launcher, or run `nz update`),
so you're never surprised by a multi-minute "Running pre-launch command" delay
with no progress bar.

---

## Setup vs update delivery

The client uses a split delivery model:

- **First install (`nz setup`)** downloads a prebuilt modpack zip from
  `https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/`. This
  stays fast because Azure serves it from CDN (~2 min) and avoids the slow
  CurseForge cold-install path.
- **Updates (`nz update`)** no longer download the whole zip. They fetch
  `latest.json`, then delta-sync `.minecraft` with `packwiz-installer` against a
  SHA-pinned `pack.toml` URL such as
  `https://raw.githubusercontent.com/camcast3/MinecraftInfra/<SHA>/packwiz/pack.toml`.
  This is the same mechanism the server uses via `PACKWIZ_URL`, and usually
  downloads only 10–50 MB instead of ~1 GB — especially helpful for AUS or
  high-latency players.

The published `latest.json` manifest includes:

- `version`
- `url` (first-install zip)
- `sha256`
- `sizeBytes`
- `instance`
- `publishedAt`
- `packwizUrl` (SHA-pinned raw `pack.toml`)
- optional `allowDowngrade`

---

## How the launch-time check works

When you click **Play**, Prism runs the `nz check` hook (its PreLaunchCommand).
It:

1. Reads your installed version from
   `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.negativezone-version`.
2. Fetches the gated `latest-version.txt` pointer from Azure Blob Storage.
3. Compares the two as strict equality.

**Cost:** one tiny GET per launch. GitHub's CDN serves it, so we don't pay
Azure egress per player launch, and you don't depend on the modpack blob
being warm.

**Outcomes:**

| Installed | Server | Result |
|---|---|---|
| `0.4.2` | `0.4.2` | Silent pass — game launches |
| `0.4.1` | `0.4.2` | Hard block, "behind" — update via the launcher |
| `0.5.0` | `0.4.2` | Hard block, "ahead" — usually means a rollback is needed |
| anything | unreachable (no internet, 404, 5xx) | Pass with `allowing launch` notice; offline play works |

The pointer changes only after the publish PR is merged, the public server
answers a Minecraft status request, and its MOTD advertises the new version.
If an old install still has PowerShell hooks, re-run the
`nz-latest/install.ps1` one-liner once to replace them with the verified nz
binary and gated pointer.

---

## What the block looks like

When your version doesn't match, you'll see this in Prism's pre-launch
console window:

```
════════════════════════════════════════════════════════════
  MODPACK VERSION MISMATCH
  installed: v0.4.1
  server:    v0.4.2  (behind)
════════════════════════════════════════════════════════════

The server is pinned to a specific modpack version.
Joining with a different client version would fail at the FML handshake.

Run this to update:

  nz update

Walk-through: https://wiki.negativezone.cc/updating
(Set NEGATIVEZONE_SKIP_VERSION_CHECK=1 to bypass for offline play.)
```

The block says `nz update`, but `nz` isn't on your PATH — the no-typing way is
to **double-click the `Update Craft to Exile 2` launcher** on your Desktop
(see below).

The direction hint (`behind` or `ahead`) tells you what's going on:

- **`behind`** — you're on an older version. Update via the **Update Craft to Exile 2** launcher.
- **`ahead`** — you're on a newer version than the server. This usually means
  you tested a pre-release and the server hasn't moved up to it yet, or the
  admin rolled the server back to fix a bug. Re-run the update —
  by default it refuses to "downgrade" you, so the admin will need to set
  `allowDowngrade: true` in the manifest. Reach out and they'll do it.

---

## Updating manually

When you see the block:

1. **Close Prism completely** (file → quit, or close the window). The update
   touches files in your instance and can't do that while Prism has them open.
2. **Double-click `Update Craft to Exile 2`** on your Desktop. A console window
   opens, runs the update, and tells you when it's done.

   Prefer a terminal? Open a **new** PowerShell window and run:

   ```powershell
   & "$env:LOCALAPPDATA\NegativeZone\nz.exe" update
   ```

3. `nz update`:
   - Auto-detects the Craft to Exile 2 instance and refuses to run while Prism
     is open.
   - Fetches `latest.json` from Azure Blob Storage.
   - Compares your `.negativezone-version` to `manifest.version` and skips if
     they already match.
   - Refuses downgrades unless the manifest has `allowDowngrade: true`.
   - Forces a safety snapshot first (waypoints, options, etc. — see [Backups]({% link backups.md %})).
   - Creates a checksum-verified immutable backup outside the live instance.
   - Seeds a sibling staging instance, then runs `packwiz-installer` with CWD
     set to the staged `.minecraft`:
     ```text
     java -jar packwiz-installer-bootstrap.jar --bootstrap-no-update --bootstrap-main-jar packwiz-installer.jar -g -s client <packwizUrl>
     ```
   - Reapplies the declared preserve list, validates the stage, atomically swaps
     it into place, and writes `.negativezone-version` last.

   The packwiz jars (`packwiz-installer-bootstrap` v0.0.3 and
   `packwiz-installer` v0.5.14) ship inside the modpack zip under `.minecraft\`
   (and `nz` caches them under `.negativezone\` as a fallback), so update doesn't
   re-download those tools each time. They need Java 17+, which Path A installs
   via Temurin 17 during onboarding.

   `packwiz-installer` only touches tracked modpack files in the stage. Personal
   state such as saves, options, Xaero maps, shaderpacks, and preserve-list
   configs is then copied declaratively from the old live instance. If a
   process or machine stops mid-update, the next run recovers the transaction
   journal before doing new work.

4. **Reopen Prism, click Play.** The version check now silent-passes, the
   game launches normally.

A typical update downloads **10–50 MB** and takes **30–90 seconds** depending
on your internet speed and how big the version delta is.

> **Resetting a tuned setting back to pack defaults:** Just delete the
> relevant config file from `%APPDATA%\PrismLauncher\instances\Craft to Exile 2\.minecraft\config\`
> (e.g. `embeddium-options.json`, `oculus.properties`) — the next pack
> update will reseed the pack-recommended baseline. The pack ships
> opinionated defaults for graphics, shaders, and UI on first install;
> from there it's yours to tweak.

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

## Replacing a legacy PowerShell install with nz
{: #upgrading-to-v050 }

The legacy PowerShell client channel is retired. A single `nz.exe` now owns
setup, launch checks, backups, updates, migration, and recovery diagnostics.

### Do this once

1. **Close Prism completely.**
2. Open PowerShell (Windows key → `powershell` → **Enter**) and run:

   ```powershell
   irm https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/install.ps1 | iex
   ```

That single command installs the current nz client and modpack in one pass.
It **preserves your worlds, waypoints, options, and tuned settings**, and saves
your previous install as a `Craft to Exile 2.bak` folder you can roll back to.

### What changes after you upgrade

- **Launch check & backups run through nz.** Your Prism hooks are rewritten
  from the old `prelaunch-check.ps1` / `backup.ps1` to `nz check` / `nz backup`
  automatically — nothing for you to wire up.
- **Updating is a double-click.** A new **Update Craft to Exile 2** launcher
  lands on your Desktop. From now on you update by double-clicking it or
  running `nz update`.
- **Your settings carry over.** Same `NEGATIVEZONE_*` environment variables and
  the same `.negativezone-version` marker — no reconfiguration needed.

> **Coming from an even older, non-version-checked install?** Same fix: run the
> one-liner above once. You'll get the launch-time check, the auto-backups, and
> the Desktop update launcher all in one step. It preserves your worlds,
> waypoints, options, and any other user state.

---

## Release cadence

What you can expect from each version bump:

| Bump | Example | What it means for you |
|---|---|---|
| **PATCH** | `0.4.1` → `0.4.2` | Usually a small client/config change. The current publish transaction still briefly redeploys the server so its MOTD, packwiz SHA, and client manifest remain one auditable version. |
| **MINOR** | `0.4.x` → `0.5.0` | Client + server in sync — usually a new mod or a major mod upgrade that needs the server-side too. The server briefly restarts on publish (~30 sec); you might see "Server unavailable" for a moment. |
| **MAJOR** | `0.x.y` → `1.0.0` | Reserved for "we've gone a full month without management-caused downtime" — a stability milestone, not a content gate. |

The strict-equality check blocks every delta — including PATCH — until the
update pipeline is rock-solid in production. We may relax this to
"MINOR-or-greater only" once a few real releases have been exercised
end-to-end without surprises.

---

## Maintainer: local compatibility corpus

`client\scripts\build-instance-corpus.ps1` discovers local Prism instances,
refuses active, locked, changing, unreadable, or reparse-point trees, and
creates sanitized checksum manifests under the Git-ignored
`.artifacts\instance-corpus\` directory. It excludes logs, worlds, screenshots,
account/cache databases, server lists, environment files, keys, and tokens.

The script runs the updater only against writable copies of those immutable
snapshots. Packwiz is replaced by an in-process test double, so it neither
downloads production data nor launches Minecraft:

```powershell
pwsh client\scripts\build-instance-corpus.ps1
```

Review the generated `report.json` for copied, tested, and explicitly skipped
instances. Corpus artifacts are local evidence only and must never be added to
Git.

CI also creates a disposable synthetic corpus and package. Changes under
`packwiz/`, the preserve list, migration/update code, or packaging scripts must
pass Go unit tests, `go vet`, the full nz E2E suite, corpus compatibility, and
package structure/checksum validation before release or modpack publication.
