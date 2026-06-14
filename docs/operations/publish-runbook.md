# Publish a new modpack version

## TL;DR

Run `gh workflow run publish-prism-pack.yml -f version=0.3.1` (or push a
`modpack/v0.3.1` tag) to kick off `.github/workflows/publish-prism-pack.yml`.
The workflow builds a clean Prism Launcher instance from the `packwiz/`
manifest, zips and uploads it to the `minecraft-modpack` blob container on
`stmcminecraftprod`, rewrites `docker/proxmox/docker-compose.yml`
(`PACKWIZ_URL` + `MOTD`) and `modpack.yml`, and opens a publish PR against
`main` from branch `modpack/v<version>`, and **enables auto-merge** on it
(`gh pr merge --auto --squash --delete-branch`). The PR squash-merges as soon
as required status checks pass (immediately if none are configured); Portainer
GitOps then detects the compose change and redeploys C2E2 within ~5 minutes.
End-to-end, the only manual step is triggering the workflow.

---

## What the workflow does

1. **Resolves the version** — from `inputs.version` (workflow_dispatch) or
   strips the `modpack/v` prefix from `GITHUB_REF_NAME` (tag push).
   Rejects versions containing characters unsafe for branch names, blob
   filenames, or JSON (only `[A-Za-z0-9.+_-]` allowed).

2. **Checks out `main`** with full history (`fetch-depth: 0`) regardless of
   trigger — the publish script always branches off `origin/main`.

3. **No-op short-circuit** — reads `version:` from `modpack.yml`. If it
   already matches the requested version, the workflow writes a summary and
   exits cleanly with no side effects (no blob upload, no file edits, no PR).

4. **Verifies clean `packwiz/` tree** — `git diff --exit-code HEAD -- packwiz/`
   ensures the checked-out manifest matches `origin/main` exactly, so the
   SHA pin in the compose file can't drift from the bundled zip.

5. **Materializes the staging instance** via
   `infra/azure/scripts/build-instance-from-packwiz.ps1`:
   - Reads Forge and Minecraft versions from `packwiz/pack.toml`.
   - Downloads (or restores from cache) `packwiz-installer-bootstrap.jar`
     (`infra/azure/scripts/cache/`; cache key `pwiz-bootstrap-v0.0.3`).
   - Creates `build/Craft to Exile 2/` from scratch; runs
     `packwiz-installer-bootstrap -g -s client` inside `.minecraft/` to pull
     every client-side mod into the staging tree (`-s client` skips
     server-only overlays like PCF, spark, prom-exporter).

6. **Azure OIDC login** via `azure/login@v3` using
   `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID`.

7. **Publishes** via `infra/azure/scripts/publish-prism-pack.ps1 -Version <ver>`:
   - Zips the staging instance; excludes saves, logs, screenshots,
     `options.txt`; keeps mods, configs, resourcepacks, shaderpacks,
     `servers.dat`, `instance.cfg`.
   - Sanitizes `instance.cfg`: strips local `JavaPath`/`JavaSignature`,
     sets `AutomaticJava=true`, pins C2E2-friendly memory defaults,
     forces `iconKey`, drops play-time/window-layout state, sets
     `name=Craft to Exile 2 v<ver>`, writes the `PreLaunchCommand` hook
     that runs the bundled `update.ps1` on every player launch.
   - Bundles the repo-tracked `cte2-icon.png` at
     `icons/<IconKey>.<ext>` inside the zip.
   - Bundles `update.ps1` at
     `Craft to Exile 2/.negativezone/update.ps1` inside the zip.
   - Computes SHA-256 of the zip.
   - Uploads `c2e2-v<ver>.zip` to the `minecraft-modpack` blob container
     on `stmcminecraftprod` with cache-immutable headers (public read).
   - Rewrites `docker/proxmox/docker-compose.yml` in-place:
     - `PACKWIZ_URL` → SHA-pinned `raw.githubusercontent.com` URL
       (commit SHA of `origin/main` HEAD at publish time).
     - `MOTD` → `Craft to Exile 2 v<ver>`.
   - Bumps `modpack.yml` (version, blob name, sha256, URL, publishedAt).
   - Commits both files to a new `modpack/v<ver>` branch and pushes.
   - Opens a PR against `main` via `gh pr create`.
   - Uploads `latest.json` **after** the PR branch is pushed, so the
     audit trail (the PR) always exists before any player can resolve the
     new version URL.

8. **Auto-merge** — the script calls
   `gh pr merge $prUrl --auto --squash --delete-branch`
   (`publish-prism-pack.ps1` line 720). The PR squash-merges as soon as
   required status checks pass; if no required checks are configured for the
   publish PR, the merge is immediate. Portainer GitOps polls `docker/proxmox/`
   on a ~5-minute interval; C2E2 redeploys automatically once the compose
   change lands on `main`.

---

## Trigger options

### Option A: Manual dispatch (recommended for most publishes)

```bash
gh workflow run publish-prism-pack.yml -f version=0.3.1
```

Or via the GitHub UI: **Actions → Publish Prism Pack → Run workflow**, enter
the version (no `v` prefix), click **Run workflow**.

Watch progress:

```bash
gh run watch --repo camcast3/MinecraftInfra
```

### Option B: Push a versioned tag

```bash
git tag modpack/v0.3.1
git push origin modpack/v0.3.1
```

Use this when you want a named git tag as part of the release record — e.g.,
for changelog coordination, linking a GitHub Release to a specific publish, or
when the publish is part of a larger release ceremony that other automation
keys off. Option A produces identical artifacts with no tag overhead; use
Option B only when the tag itself carries meaning.

---

## Forever-loop prevention (why the workflow doesn't auto-retrigger)

The publish workflow modifies `docker/proxmox/docker-compose.yml` and
`modpack.yml`, then opens a PR that eventually merges to `main`. Any trigger
that listens on those paths or on pushes to `main` would re-fire on every
publish-PR merge — creating an infinite loop.

**The trigger allow-list is exhaustive and intentionally narrow:**

| Trigger | Status | Reason |
|---|---|---|
| `workflow_dispatch` | ✅ ALLOWED | Admin-initiated only |
| `push: tags: modpack/v*` | ✅ ALLOWED | Human-pushed tag; the workflow never creates these tags |
| `push: branches: [main]` | ❌ FORBIDDEN | Fires on every publish-PR merge |
| `push: paths: [docker/proxmox/**]` | ❌ FORBIDDEN | Fires on every publish-PR merge |
| `push: paths: [modpack.yml]` | ❌ FORBIDDEN | Fires on every publish-PR merge |
| `pull_request` on publish branch | ❌ FORBIDDEN | Not needed; commit is already on the branch the script pushed |

The workflow's comment block at the top of
`.github/workflows/publish-prism-pack.yml` is the canonical source of truth
for this analysis. If you're tempted to add a new trigger, re-read that block
and redo the loop analysis before touching the `on:` section.

Loop prevention rests entirely on the trigger allow-list. Auto-merge on the
publish PR is **safe** because `push: branches: [main]` is not a trigger —
the publish-PR merge commit can't fire another publish run. (Auto-merge is
also a player/server-safety feature: without it, `latest.json` would flip
before the server redeploys, creating a mod-set mismatch window where
players can't join.)

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Workflow exits immediately with "No-op publish" summary | `modpack.yml` already pinned to that version | Bump the version input; or run `publish-prism-pack.ps1 -Version <ver> -Force` locally if you need to overwrite the existing branch/blob |
| Workflow blocked on "Waiting for concurrency group" | Another publish run is in-flight | Wait for it; `publish-prism-pack` concurrency group serialises runs with `cancel-in-progress: false` to prevent partial state |
| "Azure login failed" / OIDC error | Federated credential missing or subject mismatch | See "Azure one-time setup" below |
| "Verify clean packwiz/ tree" step fails | Something modified `packwiz/` between checkout and the verify step (shouldn't happen on GitHub-hosted runners) | Re-run the workflow; if it keeps failing, check whether a bot commit landed between queue time and execution, then file an issue |
| Publish PR opened but Portainer didn't redeploy after merge | Portainer GitOps poll cadence is ~5 min | Wait 5 min, then check the C2E2 stack's "Stack" view in Portainer for the deploy log; if still nothing, verify the GitOps config points at `docker/proxmox/` on `main` |
| `packwiz-installer-bootstrap` step downloads the JAR every run | Cache miss — bootstrap version key changed | Check that `pwiz-bootstrap-v0.0.3` in the `actions/cache` step matches `$BootstrapVersion` in `build-instance-from-packwiz.ps1`; update the cache key to match after a bootstrap upgrade |
| Version rejected with "characters that aren't safe" | Version string contains spaces, `@`, `/`, or other metacharacters | Use only `[A-Za-z0-9.+_-]` — e.g. `0.3.1` or `2026.06.13` |
| `gh pr create` fails with "already exists" | A `modpack/v<ver>` branch + PR were already pushed (e.g. partial run) | Delete the branch and close the draft PR, then re-run; or use `-Force` locally |
| `az storage blob upload` fails with 403 | The workflow's managed identity lacks `Storage Blob Data Contributor` on the `minecraft-modpack` container | See "Azure one-time setup" — check the role assignment scope |

---

## Rollback

If a bad publish merges to `main`:

```bash
git revert <publish-commit-sha>
git push origin main
```

Portainer GitOps detects the revert within ~5 minutes and redeploys C2E2
with the previous `PACKWIZ_URL` SHA pin and `MOTD`.

**Blob state:** each publish uploads a new filename (`c2e2-v<ver>.zip`) — no
blob is overwritten. The bad zip stays in the container indefinitely; it's
inert once `latest.json` no longer points at it.

**`latest.json`:** the revert does not update `latest.json` — it still points
at the bad version. Manually overwrite it:

```bash
# Replace with the last-known-good version details from modpack.yml
az storage blob upload \
  --account-name stmcminecraftprod \
  --container-name minecraft-modpack \
  --name latest.json \
  --data '{"version":"0.3.0","url":"https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/c2e2-v0.3.0.zip","sha256":"<sha256>"}' \
  --overwrite \
  --auth-mode login
```

Get the SHA256 from the `modpack.yml` entry for that version in git history.

---

## Azure one-time setup (admin only)

Required once before the OIDC auth step can succeed.

### Federated credential (Workload Identity Federation)

Create a federated credential on the publish managed identity with these
subjects:

| Subject | When it fires |
|---|---|
| `repo:camcast3/MinecraftInfra:environment:production` | Every workflow job that specifies `environment: production` (both publish and deploy workflows) |
| `repo:camcast3/MinecraftInfra:ref:refs/heads/main` | Optional — useful for ad-hoc testing without the environment gate |

The publish workflow specifies `environment: production` (line 57), so the
first subject is the required one.

### Role assignment

Grant the publish identity **Storage Blob Data Contributor** scoped to the
`minecraft-modpack` container on the `stmcminecraftprod` storage account:

```bash
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee <client-id-of-publish-identity> \
  --scope "/subscriptions/<sub>/resourceGroups/rg-minecraft-prod/providers/Microsoft.Storage/storageAccounts/stmcminecraftprod/blobServices/default/containers/minecraft-modpack"
```

### GitHub repo secrets

These secrets are already configured for `deploy-azure.yml`; the publish
workflow reuses them.

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | Client ID of the publish/deploy managed identity |
| `AZURE_TENANT_ID` | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |

If you want to scope tighter with a dedicated publish identity (separate from
the deploy identity), create a second managed identity with only
`Storage Blob Data Contributor` on the blob container (no VM Contributor, no
Bicep deploy rights), add its own federated credential, and store its client
ID as a separate secret (e.g. `AZURE_PUBLISH_CLIENT_ID`), updating the
`azure/login` step in `publish-prism-pack.yml` accordingly.

---

## Local testing (no Azure upload)

To dry-run the publish pipeline on your laptop without uploading:

```powershell
# 1. Build the staging instance (requires Go + Java 17 on PATH)
./infra/azure/scripts/build-instance-from-packwiz.ps1 -InstanceName "Craft to Exile 2"

# 2. Run the publish script in dry-run mode (set CI=true to skip the
#    local-vs-origin/main drift guard; no blob upload without az login)
$env:CI = 'true'
./infra/azure/scripts/publish-prism-pack.ps1 -Version 0.3.1-test
```

Setting `$env:CI = 'true'` bypasses the drift guard that fails loud when your
local `packwiz/` tree diverges from `origin/main` — safe for dry-runs, but do
**not** use this flag on a tree with uncommitted packwiz changes and expect the
resulting zip to match what CI would produce.

Without a valid `az login` session the blob upload step will fail; everything
before that (zip creation, SHA computation, compose rewrite) still runs and
lets you inspect the output artifacts under `build/`.

In practice: just run the workflow. It's faster and avoids any CI/local drift
risk entirely.
