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
| Manage allowlist / ops | edit `docker/shared/whitelist.json` + `ops.json`, push | per player |
| Bootstrap Azure infra | `infra/azure/scripts/bootstrap.ps1` | once |
| Provision the Proxmox VM | `infra/proxmox/cloud-init.yaml` + Portainer | once |
| Build / test the `nz` client | `go build` / `go test` / the manual harnesses | per change |

### Admin-triggered, then fully automated

| Trigger | Workflow | What runs unattended after |
|---|---|---|
| Push to `infra/azure/**`, `docker/azure/**`, `docker/shared/**` | `deploy-azure.yml` | Bicep + `az vm run-command` redeploy of the Velocity stack |
| Dispatch `publish-prism-pack` (or push `modpack/v*`) | `publish-prism-pack.yml` + Portainer GitOps | Opens an auto-merging PR; on merge Portainer redeploys C2E2 ~5 min later |
| Push to `client/**` | `release-nz.yml` | Builds + publishes `nz.exe` + `install.ps1` to the `nz-latest` prerelease |

### Never touch (fully automated)

See [the never-touch list](#never-touch-fully-automated-workflows) at the bottom —
`deploy-pages`, `lint-ps1`, `protect-latest-release`, `test-nz-e2e`,
`test-setup-e2e`, Renovate, `unattended-upgrades`, and Portainer polling all run
themselves.

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

- **What it does** — runs `infra/azure/scripts/publish-prism-pack.ps1`, which:
  materializes a staging instance from `packwiz/`, zips + SHA-256s it, uploads a
  versioned blob to the `minecraft-modpack` container, rewrites
  `docker/proxmox/docker-compose.yml` (PACKWIZ_URL SHA pin + MOTD),
  `docker/azure/velocity/velocity.toml.tmpl` (fallback MOTD), and
  `docs/assets/latest-version.txt` (the launch-time pointer `nz check` reads),
  bumps `modpack.yml`, opens an auto-merging PR from `modpack/v<version>`, then
  uploads `latest.json` **after** the PR succeeds. Portainer GitOps redeploys
  C2E2 within ~5 min of merge.
- **Notes** — **no-op aware**: if `modpack.yml` already pins the requested
  version the workflow exits before any side effect. Re-publishing the same
  version needs a local `publish-prism-pack.ps1 -Version <v> -Force`. The
  workflow is serialized (`concurrency: publish-prism-pack`). To run the whole
  thing locally you need `az login` (Storage Blob Data Contributor on the
  container) and `gh` auth.

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

- **Why** — add or remove allowlisted players, or grant/revoke operator level.
- **Prerequisites** — the player's Minecraft Java **UUID** (with dashes) + name.
- **How** — edit the shared files and push to `main`:

  - `docker/shared/whitelist.json` — `{ "uuid": "...", "name": "..." }` entries.
  - `docker/shared/ops.json` — adds `"level"` (1–4) and `"bypassesPlayerLimit"`.

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
  | `NEGATIVEZONE_NZ_EXE_URL` | `install.ps1` | Override the `nz.exe` download URL (e.g. a fork/test release). |
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
  `PostExitCommand=… backup` into `instance.cfg`.
- **Notes** — safe to re-run. The version-skip path never touches `.minecraft`,
  so it can't disturb worlds/settings. For a zero-risk full lifecycle test
  (including a fresh `setup`) against a fake Azure, use the
  [sandbox harness](#manual-harness--sandbox-zero-risk) instead.

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
  # ... nz setup / nz check / nz backup / nzPublish 1.0.1 / nz update / nz migrate ...
  pwsh client/scripts/manual-e2e.ps1 down
  ```

- **Notes** — defaults to the fake-packwiz seam (instant, offline). Pass
  `-RealPackwiz` to exercise the real `packwiz-installer` (needs Java 17 +
  network).
- **Validate a specific version (e.g. 0.4.3).** The sandbox seeds `1.0.0` →
  `1.0.1`. `nzPublish <ver>` republishes the "latest" manifest to any version,
  but mind the **downgrade gotcha**: `nz update` refuses to move from the seeded
  `1.0.0` *down* to `0.4.x` unless you pass `-AllowDowngrade` to `nzPublish`
  (which exercises the downgrade path, not a clean forward update). For a clean
  **forward** test like `0.4.2 → 0.4.3`, change the two seed versions near the
  top of `manual-e2e.ps1` (the `New-FakeZip` / `Write-LocalManifest` calls) to
  your base version, then drive `setup → check → backup → nzPublish 0.4.3 →
  check → update`.

### Legacy setup e2e (deprecated path)

- **Why** — exercise the **legacy** PowerShell `setup.ps1` / `update.ps1` /
  `backup.ps1` flow. Kept only while those scripts still ship.
- **How**:

  ```powershell
  pwsh infra/azure/scripts/test-setup-e2e.ps1
  ```

- **Notes** — superseded by the `nz` e2e suite. See the
  [deprecation register](#deprecation-register).

---

## Never-touch (fully automated) workflows

These run themselves — no manual trigger, no babysitting:

| Workflow / mechanism | What it does |
|---|---|
| `deploy-pages.yml` | Builds + publishes this docs site to GitHub Pages |
| `lint-ps1.yml` | Lints PowerShell scripts |
| `protect-latest-release.yml` | Re-pins the GitHub "Latest" release to the newest `setup-v*` |
| `test-nz-e2e.yml` | Runs the `nz` e2e suite on `client/**` PRs + `main` pushes |
| `test-setup-e2e.yml` | Runs the legacy setup e2e |
| Renovate | Bumps pinned image digests (`image:tag@sha256:...`) |
| `unattended-upgrades` | Daily OS security patches + off-peak auto-reboot on both VMs |
| Portainer GitOps polling | Redeploys `docker/proxmox/` on git changes (~5 min) |

---

## Deprecation register

We are committing to the `nz` cutover. The legacy PowerShell **customer**
scripts are **marked deprecated here, not deleted this pass** — a follow-up PR
can remove them once the `nz` release is live and these docs are merged.

| Deprecated | Lives at | Replaced by |
|---|---|---|
| `setup.ps1` | `docs/assets/setup.ps1` | `client/scripts/install.ps1` + `nz setup` |
| `update.ps1` | `docs/assets/update.ps1` | `nz update` |
| `prelaunch-check.ps1` | `docs/assets/prelaunch-check.ps1` | `nz check` |
| `backup.ps1` | `docs/assets/backup.ps1` | `nz backup` |
| `migrate-settings.ps1` | `docs/assets/migrate-settings.ps1` | `nz migrate` |
| `release-setup-script.yml` | `.github/workflows/` | `release-nz.yml` |
| `release-migrate-script.yml` | `.github/workflows/` | `release-nz.yml` |

**Not deprecated:** `docs/assets/latest-version.txt` is still the live
launch-time version pointer — `nz check` reads it and `publish-prism-pack.ps1`
keeps writing it. `protect-latest-release.yml` stays relevant while `setup-v*`
releases still exist.

> **Logs & diagnostics.** Every `nz` command writes a unified, full-detail
> record to `nz.log` in the instance's `.negativezone\` folder (first-install
> lines, before the instance exists, go to `%LOCALAPPDATA%\NegativeZone\nz.log`).
> This replaces the old per-command `backup.log` / `update.log`. Ask players to
> run `nz support` — it zips `nz.log`, the version marker, `instance.cfg`, and an
> env summary to their Desktop. Global flags `--verbose` / `--quiet` only affect
> the console; the file always captures DEBUG-level detail.

> **Going live.** `release-nz.yml` hasn't run on `main` yet, so no
> `nz-latest` prerelease exists and the docs above point at
> `releases/download/nz-latest/…`. **Merging these changes is what goes live** —
> the push to `client/**` cuts the `nz-latest` prerelease and the player
> one-liner starts resolving.

> **Player cutover = v0.5.0.** Publishing **v0.5.0** (with its new mods) is the
> forcing function for players: older clients can't join until they upgrade, and
> the upgrade one-liner installs nz. Point players at
> [Upgrading to v0.5.0]({% link updates.md %}#upgrading-to-v050). Note the
> currently published zip still wires the legacy PS1 hooks
> (`publish-prism-pack.ps1`) and bundles `update.ps1` / `backup.ps1` /
> `prelaunch-check.ps1`; `nz setup` overwrites the live Prism hooks to
> `nz check` / `nz backup` on upgrade, so players land on nz regardless, leaving
> only harmless orphaned `.ps1` files in `.negativezone\` until a later publish
> stops bundling them.
