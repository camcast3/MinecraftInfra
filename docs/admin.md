---
layout: default
title: Admin & dev runbook
nav_exclude: true
---

# Admin & dev runbook
{: .no_toc }

Every **manual** action an admin or developer takes, with the exact path,
command, and effect. This page is intentionally hidden from the public site
nav (`nav_exclude: true`) — it lives with the docs but isn't player-facing.

> **Public-repo safe.** No secrets here — Key Vault items and environment
> variables are referenced **by name only**.

<details markdown="1" open>
<summary>Table of contents</summary>

* TOC
{:toc}
</details>

---

## Manual vs automated — the one-screen summary

The repo has ~30 scripts, commands, and workflows. The anxiety-killer: you only
ever *trigger* a handful by hand. Everything else is CI or polling.

### You run these by hand

| Action | Path / command | Frequency |
|---|---|---|
| Publish a new modpack version | `publish-prism-pack.yml` (dispatch + version, **or** push a `modpack/v*` tag) | per release |
| Import/refresh CurseForge mods | `infra/azure/scripts/import-curseforge-pack.ps1` | per upstream bump |
| Build a staging/hotfix instance | `infra/azure/scripts/build-instance-from-packwiz.ps1` | rare (usually CI) |
| Manage allowlist / ops | edit `docker/shared/whitelist.json`, run `scripts/sync-ops.ps1`, push | per player |
| Bootstrap Azure infra | `infra/azure/scripts/bootstrap.ps1` | once |
| Provision the C2E2 VM | `infra/proxmox/cloud-init.yaml` + Portainer | once |
| Build / test the `nz` client | `go build` / `go test` / the manual harnesses | per change |

### Admin-triggered, then fully automated

| Trigger | Workflow | What runs unattended after |
|---|---|---|
| Push to `infra/azure/**`, `docker/azure/**`, `docker/shared/**` | `deploy-azure.yml` | Bicep + `az vm run-command` redeploy of the Velocity stack |
| Dispatch `publish-prism-pack` (or push `modpack/v*`) | `publish-prism-pack.yml` + Portainer GitOps | Opens an auto-merging PR; on merge Portainer redeploys C2E2 ~5 min later |
| Push to `client/**` | `release-nz.yml` | Gates and publishes immutable `nz-v<commit>` assets, then refreshes the `nz-latest` production release |

### Never touch (fully automated)

See [the never-touch list](#never-touch-fully-automated-workflows) at the bottom —
`deploy-pages`, `lint-ps1`, `test-nz-e2e`, Renovate,
`unattended-upgrades`, and enabled Portainer GitOps polls run themselves.

> **Excluded entirely:** `old/` (archived) and `admin_compose.yml`. Don't
> reference or modify them.

---

## How to read each entry

Every task below uses the same template:

> - **Why** — the trigger/purpose: when and why you run it.
> - **Prerequisites** — tools, auth, env vars, etc.
> - **How** — the exact command with its real path (copy-pasteable).
> - **What it does** — outcome + side effects (files written, services touched).
> - **Notes** — gotchas, safe-to-rerun?, how to undo.

---

## Admin tasks

### Publish a new modpack version

- **Why** — ship a new modpack version so the server **and** every client move
  in lockstep.
- **Prerequisites** — admin access. Repo settings must have *Allow GitHub
  Actions to create and approve pull requests* **and** *Allow auto-merge*
  enabled (the publish PR self-merges). The workflow logs into Azure via OIDC.
- **How** — trigger the workflow either way:

  ```powershell
  # Preferred: workflow_dispatch with the version input
  gh workflow run publish-prism-pack.yml -f version=0.4.3

  # Or push a tag
  git tag modpack/v0.4.3
  git push origin modpack/v0.4.3
  ```

- **What it does** — first runs Go tests/vet, full nz E2E, synthetic corpus,
  and disposable packaging validation. It then runs
  `infra/azure/scripts/publish-prism-pack.ps1`, which materializes a staging
  instance from `packwiz/`, zips + SHA-256s it, uploads immutable versioned zip
  and manifest candidates to the `minecraft-modpack` container, rewrites
  `docker/proxmox/docker-compose.yml` (PACKWIZ_URL SHA pin + MOTD),
  `docker/azure/velocity/velocity.toml.tmpl` (fallback MOTD), bumps
  `modpack.yml`, and opens an auto-merging PR from
  `modpack/v<version>`. Portainer GitOps redeploys C2E2 within ~5 min of merge.
  `promote-prism-pack.yml` then waits for the public Minecraft status response
  to advertise that version before updating `latest.json` and
  `latest-version.txt`.
- **Notes** — **no-op aware**: if `modpack.yml` already pins the requested
  version the workflow exits before any side effect. Re-publishing the same
  version needs a local `publish-prism-pack.ps1 -Version <v> -Force`. The
  workflow is serialized (`concurrency: publish-prism-pack`). To run the whole
  thing locally you need `az login` (Storage Blob Data Contributor on the
  container) and `gh` auth.
- **Local-publish mode (no Azure, no git).** Pass `-LocalOutDir <dir>` to run the
  **identical** packaging path (sanitize `instance.cfg`, bundle icon +
  preserve-list.json, apply exclusions, structural mod-JAR sanity
  check, compute SHA-256, build `latest.json`) but write the versioned zip +
  manifest to a local directory instead of uploading to Azure / opening a PR.
  Targets any version tag, needs neither `az` nor `gh`. This is how you stage a
  publish-faithful local zip (e.g. for the upgrade mock below) without touching
  production storage:

  ```powershell
  ./infra/azure/scripts/publish-prism-pack.ps1 `
    -Version 0.4.3 -InstancePath "<a Prism instance>" `
    -LocalOutDir "$env:TEMP\nzpub" -LocalBaseUrl "http://127.0.0.1:8788"
  # -> $env:TEMP\nzpub\c2e2-v0.4.3.zip + latest.json (url -> the loopback base)
  ```

  `-LocalOutDir` is mutually exclusive with `-SkipDriftCheck` (it's already fully
  local) and never mutates the source instance (the sanitized cfg is written only
  into the zip).

### Build a staging / hotfix instance

- **Why** — materialize a clean Prism instance from the committed packwiz
  manifest, e.g. to hand-curate a hotfix before publishing, or to inspect.
- **Prerequisites** — Java 17+ on PATH; network access for the pinned
  `packwiz-installer` jars on first run; optionally `CURSEFORGE_API_KEY` to
  avoid CurseForge rate limits on the ~390-mod install.
- **How**:

  ```powershell
  ./infra/azure/scripts/build-instance-from-packwiz.ps1 -InstanceName "Craft to Exile 2"
  ```

  It prints the staging path (default `<RepoRoot>/build/`).
- **What it does** — reads loader/MC versions from `packwiz/pack.toml`, wipes any
  prior staging dir, writes a minimal `instance.cfg` + `mmc-pack.json`, and runs
  `packwiz-installer-bootstrap` against the local working tree via a `file://`
  URL.
- **Notes** — normally this is just a CI step inside the publish workflow. Run it
  locally only for a hand-curated hotfix, then feed it to publish:

  ```powershell
  $staging = ./infra/azure/scripts/build-instance-from-packwiz.ps1
  ./infra/azure/scripts/publish-prism-pack.ps1 -InstancePath $staging -Version 0.4.3
  ```

### Import / refresh CurseForge mods

- **Why** — bump C2E2 to a new upstream CurseForge release while preserving the
  three server-only overlay mods.
- **Prerequisites** — the packwiz CLI on PATH
  (`go install github.com/packwiz/packwiz@latest`); the C2E2 CurseForge zip
  (manual download from the CurseForge *Files* tab); optionally
  `CURSEFORGE_API_KEY`.
- **How**:

  ```powershell
  ./infra/azure/scripts/import-curseforge-pack.ps1 -PackZip 'C:\Downloads\Craft+To+Exile+2-0.4.0.zip'
  ```

- **What it does** — `packwiz curseforge import` recreates the pack from scratch,
  so this script snapshots the three server overlay mods (`spark`,
  `Proxy-Compatible-Forge`, `minecraft-prometheus-exporter`), runs the import,
  re-adds the overlays at pinned URLs with `side="server"`, syncs `FORGE_VERSION`
  into `docker/proxmox/docker-compose.yml`, and `packwiz refresh`es the index.
- **Notes** — **review the `git status` diff before committing.** Pass
  `-YesAllPrompts` for non-interactive/CI runs. After committing, publish a new
  version (above) to roll it out.

### Manage allowlist / ops

- **Why** — add or remove allowlisted players. Every allowlisted player is
  generated as a level-3 operator.
- **Prerequisites** — the player's Minecraft Java **UUID** (with dashes) + name.
- **How** — edit the whitelist, regenerate the operator file, and push to `main`:

  ```powershell
  .\scripts\sync-ops.ps1
  .\scripts\sync-ops.ps1 -Check
  ```

  `docker/shared/ops.json` is generated from each whitelist entry by preserving
  `uuid` and `name`, then adding `"level": 3` and
  `"bypassesPlayerLimit": false`. Do not edit it by hand. CI runs the script in
  check mode and fails if the committed output differs; production publish and
  deploy workflows repeat the check and stop before release or deployment.

- **What it does** — the C2E2 backend reads `WHITELIST_FILE` / `OPS_FILE` from the
  raw GitHub URLs and runs with `EXISTING_WHITELIST_FILE=SYNCHRONIZE` /
  `EXISTING_OPS_FILE=SYNCHRONIZE`, so **git is authoritative** — in-game
  `/whitelist add` and `/op` are reverted on restart. `ENFORCE_WHITELIST=TRUE`.
- **Notes** — changes apply on the next backend restart/redeploy. Push triggers
  Portainer GitOps; to apply immediately, restart the C2E2 stack in Portainer.
  Don't bother running `/whitelist add` in-game — it won't stick.

### Bootstrap Azure infra (once)

- **Why** — one-time creation of the Azure resource group, GitHub OIDC identity,
  Key Vault, and secrets, before the first automated deploy.
- **Prerequisites** — Azure CLI (`winget install Microsoft.AzureCLI`), `az login`,
  and an SSH key (`ssh-keygen -t ed25519 -C "mc-azure-vm"`).
- **How**:

  ```powershell
  .\infra\azure\scripts\bootstrap.ps1
  ```

- **What it does** — creates `rg-minecraft-prod` (westus); a GitHub Actions App
  Registration + Service Principal with a federated credential (environment
  `production`, no stored password); role assignments; a standalone Key Vault
  deploy; populates KV secrets; and creates the Proxmox backup SP. It prints the
  values you need next.
- **Notes** — after it runs: fill the `prod.bicepparam` TODOs
  (`githubActionsObjectId`, `proxmoxSpObjectId`), add the GitHub Actions secrets
  (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`), add the
  Portainer environment variables, then push to `main`. Every subsequent
  infra/stack deploy is automated by `deploy-azure.yml`.

### Provision the Proxmox VM (once)

- **Why** — stand up the home Proxmox VM that runs the C2E2 backend.
- **Prerequisites** — a Proxmox host and the Debian 13 cloud-init.
- **How** — provision the VM with `infra/proxmox/cloud-init.yaml`, install
  Portainer CE, then create a **GitOps stack** in Portainer pointing at
  `docker/proxmox/docker-compose.yml` with all env vars set in the Portainer
  stack UI.
- **What it does** — cloud-init configures Debian 13 (`unattended-upgrades`,
  hardened SSH, Tailscale, Docker). Portainer CE then polls this repo and
  redeploys C2E2 on changes under `docker/proxmox/`.
- **Notes** — **secrets go in the Portainer environment UI only** — no `.env`
  files in git. SSH/user/port details are defined in `cloud-init.yaml`; the home
  VM is reachable only over Tailscale (public port 22 is blocked).

---

## Dev tasks (the `nz` client)

All commands run from the `client/` directory unless noted.

### Build the client

- **Why** — compile-check every package.
- **How**:

  ```powershell
  cd client
  go build ./...
  ```

### Build a runnable `nz.exe`

- **Why** — get a local binary to drive by hand.
- **How**:

  ```powershell
  cd client
  go build -o nz.exe ./cmd/nz/
  ```

### Install / repair on a real machine (`install.ps1` + `nz setup` levers)

- **Why** — drive the real installer end-to-end, test an **unreleased** build
  without publishing to GitHub, repair a mangled Prism `instance.cfg`, or re-wire
  hooks — all without paying for a full ~1 GB Azure modpack re-download.
- **Key behaviours**:
  - **Version-skip (default).** `nz setup` reads the installed
    `.negativezone-version`; if it already equals the manifest version it
    **skips the modpack download** and only re-asserts the Prism hooks, the
    bundled `nz.exe`, and the Update launcher. This is the cheap repair path for
    a corrupted/mangled `instance.cfg` — just re-run `nz setup`.
  - **`--force`** reinstalls the modpack even when the version matches (full
    download + user-state-preserving swap).
  - The Prism hook paths are written with **forward slashes**
    (`C:/Users/…/nz.exe`) so Qt's `instance.cfg` INI parser can't eat the
    backslashes — the historical `C:sersarlt…` mangling bug.
- **Levers** — environment variables, all admin/test only:

  | Lever | Read by | Effect |
  |---|---|---|
  | `NEGATIVEZONE_NZ_EXE_PATH` | `install.ps1` | **Copy** a local `nz.exe` instead of downloading from `nz-latest`. Test an unreleased build end-to-end. Takes precedence over the URL. |
  | `NEGATIVEZONE_NZ_RELEASE_URL` | `install.ps1` | Override the release metadata URL or use a local metadata path. |
  | `NEGATIVEZONE_NZ_EXE_URL` | `install.ps1` | Override the binary URL; requires `NEGATIVEZONE_NZ_EXE_SHA256`. |
  | `NEGATIVEZONE_NZ_EXE_SHA256` | `install.ps1` | Required SHA-256 for a binary URL override. |
  | `NEGATIVEZONE_MANIFEST_URL` | `install.ps1`, `nz setup` | Point setup at a test modpack manifest instead of the prod `latest.json`. |
  | `NEGATIVEZONE_SKIP_WINGET` | `install.ps1` | `1` skips the Java 17 + Prism winget installs. |
  | `NEGATIVEZONE_NONINTERACTIVE` | `nz setup` | `1` skips the confirm prompt (set automatically by `install.ps1`). |
  | `NEGATIVEZONE_SKIP_PRISM_CHECK` | `nz setup` | `1` bypasses the "Prism is running" guard (tests only — Prism rewrites `instance.cfg` on exit, so never skip this on a live machine). |

- **How** — test the full installer against a freshly-built binary, offline:

  ```powershell
  cd client
  go build -o "$env:TEMP\nz.exe" ./cmd/nz/

  $env:NEGATIVEZONE_NZ_EXE_PATH = "$env:TEMP\nz.exe"   # use the local build
  $env:NEGATIVEZONE_SKIP_WINGET = '1'                   # skip Java/Prism installs
  irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/client/scripts/install.ps1 | iex
  # …or run the local copy directly:
  pwsh client/scripts/install.ps1
  ```

  Repair a mangled `instance.cfg` / re-wire hooks on a live machine (no download
  when already up to date — close Prism first):

  ```powershell
  & "$env:LOCALAPPDATA\NegativeZone\nz.exe" setup          # version-skip → re-asserts hooks only
  & "$env:LOCALAPPDATA\NegativeZone\nz.exe" setup --force  # force a full modpack reinstall
  ```

- **What it does** — `install.ps1` installs Java 17 + Prism (unless skipped),
  places `nz.exe` in `%LOCALAPPDATA%\NegativeZone\`, then runs `nz setup`, which
  installs/updates the Prism instance and wires `PreLaunchCommand=… check` /
  `PostExitCommand=… backup` into `instance.cfg` (paths written with **forward
  slashes** so Qt's INI parser can't mangle them). On an **upgrade** it also
  keeps the previous install as `…\.bak`, creates a one-click-rollback
  `Craft to Exile 2 (old)` instance (launch hooks disabled), and rewrites
  `instances\instgroups.json` to sort the grid into **Latest** (live) and
  **Backup** (`.bak` + `(old)`) groups. The grouping self-heals on every run.
- **Transactions.** Setup, update, and migrate create a checksum-verified
  off-instance backup, prepare and validate a sibling stage, atomically swap it
  live, and write the version marker last. A per-instance journal recovers an
  interrupted operation on the next run. Do not manually remove transaction
  journals, sibling stages, rollback directories, or `.negativezone-backups`.
- **Backups.** The `PostExitCommand` (`nz backup`) snapshots curated user-state
  (configs, shaderpacks, resourcepacks, waypoints, options, `servers.dat`, etc.
  per `preserve-list.json`) into `.negativezone\backups\<timestamp>\` — **not**
  the whole modpack. It runs on a **3-day cadence**, so most game exits print
  `Last backup N day(s) ago; next due in …` and skip — that's expected, not a
  failure. Force one to verify: `& "$env:LOCALAPPDATA\NegativeZone\nz.exe" backup --force`
  (set `INST_DIR` to the instance, or run from its `.negativezone\nz.exe`).
- **Notes** — safe to re-run. The version-skip path never touches `.minecraft`,
  so it can't disturb worlds/settings. To preview the full upgrade experience
  (`.bak` + `(old)` + groups) without paying for an Azure download, use the
  [local-zip upgrade mock](#mock-a-full-modpack-upgrade-end-to-end-local-043-zip).
  For a zero-risk full lifecycle test against a fake Azure, use the
  [sandbox harness](#manual-harness--sandbox-zero-risk).

### Vet

- **Why** — static checks before pushing.
- **How**:

  ```powershell
  cd client
  go vet ./...
  ```

### Run the e2e suite

- **Why** — exercise the full `setup → check → backup → update → migrate`
  lifecycle. This is the same suite CI runs (`test-nz-e2e.yml`).
- **Prerequisites** — Go (per `client/go.mod`); Windows runner semantics.
- **How**:

  ```powershell
  cd client
  go test -tags e2e -v -timeout 10m ./tests/e2e/
  ```

- **Notes** — tests are tagged `//go:build e2e`. The packwiz sync has a test
  seam: `NEGATIVEZONE_PACKWIZ_CMD` overrides the real java+jars invocation so
  the suite runs offline.

### Manual harness — REAL instance (safe)

- **Why** — drive `check` / `backup` / `update` against your **live** Prism
  "Craft to Exile 2" instance without risk. `update` runs a real packwiz sync
  pinned to the SHA matching your installed mods, so it's a verified no-op; the
  version marker is auto-revertable.
- **How**:

  ```powershell
  pwsh client/scripts/manual-real.ps1 up
  . $env:TEMP\nz-manual-real\env.ps1   # loads $nz + INST_DIR + helpers
  # ... nz check / nz backup / nzPublish 0.4.3 / nz update / nzRevert ...
  pwsh client/scripts/manual-real.ps1 down   # stops server + restores marker
  ```

- **Notes** — the Prism-running guard stays ON (`update` refuses while Prism is
  open). A stray `nz setup` here fails fast without touching `.minecraft` — do
  setup testing in the sandbox below instead.

### Manual harness — sandbox (zero risk)

- **Why** — drive the **full** lifecycle (`setup` included) end-to-end against a
  loopback fake-Azure + a temp `%APPDATA%`, never touching production or your
  real Prism instances.
- **How**:

  ```powershell
  pwsh client/scripts/manual-e2e.ps1 up
  . $env:TEMP\nz-manual-e2e\env.ps1    # loads $nz + sandbox APPDATA + helpers
  # ... nz setup / nz check / nz backup / nzPublishReal 0.4.3 / nz update / nz migrate ...
  pwsh client/scripts/manual-e2e.ps1 down
  ```

- **Notes** — defaults to the fake-packwiz seam (instant, offline). Pass
  `-RealPackwiz` to exercise the real `packwiz-installer` (needs Java 17 +
  network). The sandbox sets `NEGATIVEZONE_SKIP_PRISM_CHECK=1` and a temp
  `%APPDATA%`, so it can never touch your real Prism instance.
- **Helpers loaded by `env.ps1`:**

  | Helper | Use |
  |---|---|
  | `nzStageZip <ver>` | Build a **real** local modpack zip for `<ver>` (valid `instance.cfg` / `mmc-pack.json` / `.minecraft` / preserve-list) into the loopback blob dir. |
  | `nzPublishReal <ver> [-AllowDowngrade]` | Stage the zip (if needed) **and** publish a manifest with a real SHA-256 + size, so `nz setup`'s zip verification passes. Use this to drive `nz setup` from a local zip. |
  | `nzPublish <ver> [-AllowDowngrade]` | Publish a manifest with a **placeholder** SHA (fine for the packwiz-only `nz update` path, which doesn't download the zip). |
  | `nzReset` | Wipe the installed instance + `.bak` for a clean `setup`. |

### Mock a full modpack **upgrade** end-to-end (local 0.4.3 zip)

- **Why** — see exactly what a player experiences on a version bump: the new
  instance installed from a **local** 0.4.3 zip (no Azure egress), the previous
  install preserved as a `.bak`, a one-click-rollback `Craft to Exile 2 (old)`
  instance, and Prism's grid sorted into **Latest** / **Backup** groups (the same
  grouping the legacy `setup.ps1` produced). This is the stable, repeatable way
  to validate an upgrade before publishing.
- **Prerequisites** — `pwsh` (PowerShell 7). The sandbox builds `nz.exe` and a
  loopback file server itself; nothing hits production.
- **How** — brand-new install from a local 0.4.3 zip:

  ```powershell
  pwsh client/scripts/manual-e2e.ps1 up
  . $env:TEMP\nz-manual-e2e\env.ps1
  $env:NEGATIVEZONE_NONINTERACTIVE = '1'        # skip the y/N prompt
  nzReset ; nzPublishReal 0.4.3 ; & $nz setup   # installs v0.4.3 from the LOCAL zip
  ```

  Full **upgrade** (base 0.4.2 → 0.4.3), which is what produces the `.bak`,
  `(old)`, and groups:

  ```powershell
  nzReset ; nzPublishReal 0.4.2 ; & $nz setup   # base install
  nzPublishReal 0.4.3 ; & $nz setup             # upgrade from the LOCAL 0.4.3 zip
  pwsh client/scripts/manual-e2e.ps1 down        # tear down when done
  ```

- **What to verify** (against the sandbox `%APPDATA%`):

  ```powershell
  $inst = "$env:APPDATA\PrismLauncher\instances"
  Get-Content "$inst\Craft to Exile 2\.negativezone-version"      # -> 0.4.3
  Test-Path "$inst\Craft to Exile 2.bak"                          # -> True
  Test-Path "$inst\Craft to Exile 2 (old)"                        # -> True (OverrideCommands=false)
  Get-Content "$inst\instgroups.json"                            # Latest -> live; Backup -> .bak + (old)
  ```

- **Notes** — `nz setup` is **version-aware**: if the installed
  `.negativezone-version` already equals the manifest version it **skips the
  download** and only re-asserts hooks/groups. So an upgrade test must bump the
  published version (0.4.2 → 0.4.3) or pass `nz setup --force`. The side-by-side
  `(old)` instance has its launch hooks disabled (`OverrideCommands=false`) so
  Prism's pre-launch version check won't block rolling back to it. The sandbox
  also pre-stages a separate `(old)` fixture for `nz migrate`; on a real upgrade
  the `(old)` instance is the rollback copy created from the `.bak`.

### Mock the upgrade against your REAL Prism instance

- **Why** — the sandbox above proves the mechanics in isolation; this drives the
  **same upgrade on your live Prism instance** so you can see the Latest/Backup
  groups, the `(old)` rollback instance, and the wired hooks in the real Prism
  UI. Useful as a final confidence check before publishing a real version.
- **Safe by construction** — the "new" zip is built **from your current install**
  by invoking the real `publish-prism-pack.ps1` in `-LocalOutDir` mode (same
  sanitize + bundle + structural-sanity-check packaging as a production publish,
  just written locally instead of to Azure), so the upgraded instance keeps the
  identical real mods/config and stays fully playable. Your previous install is
  preserved twice (as `…\.bak` and the `Craft to Exile 2 (old)` instance), and
  `-Action rollback` restores it.
- **Prerequisites** — Prism **and** the game fully closed (the script refuses
  otherwise — Prism rewrites `instance.cfg` on exit). Go toolchain for the
  one-shot `nz.exe` + loopback-server build. ~1.3 GB of free temp space.
- **How**:

  ```powershell
  # Build a local v0.4.3 zip from your current install, serve it on loopback,
  # and run the REAL nz setup upgrade + verify (no Azure egress):
  pwsh client/scripts/test-upgrade-real.ps1                 # 0.4.2 -> 0.4.3

  # When finished inspecting, restore your real install (matches production).
  # Close Prism first — rollback/clean also refuse while Prism is open:
  pwsh client/scripts/test-upgrade-real.ps1 -Action rollback
  pwsh client/scripts/test-upgrade-real.ps1 -Action clean   # remove temp + leftovers
  ```

- **What it verifies** — live instance is now v0.4.3; `.bak` of the previous
  version exists; `Craft to Exile 2 (old)` exists with launch hooks disabled;
  `instgroups.json` has Latest→live and Backup→`.bak`+`(old)`; the PreLaunch hook
  uses forward slashes (no Qt mangling); a backup snapshot was taken; the
  upgraded `.minecraft` still has its mods.
- **Rollback / cleanup** — `-Action rollback` moves the current (mock) instance
  aside to `Craft to Exile 2.rolledback-<timestamp>` (kept for inspection, not
  deleted), restores the previous install from `.bak`, removes the `(old)` copy,
  and resets `instgroups.json`. It requires Prism closed (same `instance.cfg`
  rewrite hazard). `-Action clean` then removes the temp staging **and** sweeps
  up any `*.rolledback-*` leftovers so they don't linger as multi-GB junk
  instances in Prism's grid.
- **Launch gotcha (important)** — the mock v0.4.3 is intentionally **ahead** of
  the published version pointer, so `nz check` (the PreLaunch hook) will
  **block launching the v0.4.3 instance** with a "version mismatch / ahead"
  message — that's the version gate working correctly. Two ways to launch-test:
  - Launch the **`Craft to Exile 2 (old)`** instance instead — it's a real
    playable copy with hooks disabled, so it launches the previous version with
    no gate.
  - Or bypass the gate for the v0.4.3 instance by exporting the skip var in the
    shell **before** starting Prism (so the hook child inherits it):

    ```powershell
    $env:NEGATIVEZONE_SKIP_VERSION_CHECK = '1'
    & "$env:LOCALAPPDATA\Programs\PrismLauncher\prismlauncher.exe"
    ```

  When done, run `-Action rollback` so your real instance matches the published
  version again.

## Never-touch (fully automated) workflows

These run themselves — no manual trigger, no babysitting:

| Workflow / mechanism | What it does |
|---|---|
| `deploy-pages.yml` | Builds + publishes this docs site to GitHub Pages |
| `lint-ps1.yml` | Lints PowerShell scripts |
| `test-nz-e2e.yml` | Runs the `nz` e2e suite on `client/**` PRs + `main` pushes |
| Renovate | Bumps pinned image digests (`image:tag@sha256:...`) |
| `unattended-upgrades` | Daily OS security patches + off-peak auto-reboot on both VMs |
| Portainer GitOps polling | Redeploys `docker/proxmox/` on git changes (~5 min) |

---

## Retired PowerShell client recovery

The PowerShell setup, update, backup, prelaunch, and migration release channels
are retired. They are not packaged, published, linked from player docs, or
tested as a second client. Their source paths and frozen
`docs/assets/latest-version.txt` remain only because already-published immutable
releases and pre-nz installs may still fetch them during recovery. See the
[archived recovery notes]({% link legacy-recovery.md %}).

> **Logs & diagnostics.** Every `nz` command writes a unified, full-detail
> record to `nz.log` in the instance's `.negativezone\` folder (first-install
> lines, before the instance exists, go to `%LOCALAPPDATA%\NegativeZone\nz.log`).
> This replaces the old per-command `backup.log` / `update.log`. Ask players to
> run `nz support` — it zips `nz.log`, the version marker, `instance.cfg`, and an
> env summary to their Desktop. Global flags `--verbose` / `--quiet` only affect
> the console; the file always captures DEBUG-level detail.

> **Release model.** `release-nz.yml` publishes a commit-versioned
> `nz-v<12-char-sha>` prerelease containing `nz.exe`, `SHA256SUMS`,
> `nz-release.json`, and `install.ps1`. Only after tests, corpus/package
> compatibility, static launch, installer verification, and public server
> health pass does it refresh `nz-latest`, the sole production bootstrap.
> Its metadata points to the immutable binary URL and `install.ps1` verifies
> the checksum before replacement.
