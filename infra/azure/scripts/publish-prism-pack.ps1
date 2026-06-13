#requires -Version 7.0
<#
.SYNOPSIS
    Export a Prism Launcher instance and publish it to Azure Blob storage so
    player setup.ps1 can pull it in seconds instead of waiting through
    a CurseForge download. Bundles update.ps1 + wires the PreLaunchCommand
    so installed instances auto-update against the latest published manifest.

.DESCRIPTION
    Steps:
      1. Reads the Prism instance directory — by default the staging instance
         produced by `build-instance-from-packwiz.ps1` at <RepoRoot>/build/,
         or an explicit -InstancePath for hand-curated test runs.
      2. Zips it into a distributable pack, excluding user-specific files
         (saves, logs, screenshots, options.txt, etc.) while keeping mods,
         configs, resourcepacks, shaderpacks, servers.dat, and instance.cfg
         (Java args + memory settings)
      3. Sanitizes instance.cfg so it imports cleanly on any player's machine:
         strips your local JavaPath/JavaSignature/etc., sets AutomaticJava=true
         so Prism picks the right Java itself, pins memory to a C2E2-friendly
         default, forces iconKey=<IconKey> so players see the branded icon,
         drops user-state fields (play time, window layout), sets
         `name=<InstanceName> v<Version>` so Prism's instance grid shows
         the live version, and writes the `PreLaunchCommand` hook that
         runs the bundled update.ps1 on every launch
      4. Bundles the repo-tracked instance icon (default: cte2-icon.png next to
         this script) into the zip at top-level `icons/<IconKey>.<ext>` so the
         icon is reproducible regardless of what the admin's local Prism has
         set (Prism stores icons globally at %APPDATA%\PrismLauncher\icons\,
         not inside the instance folder)
      5. Bundles the player-side update.ps1 into the zip at
         <InstanceName>/.negativezone/update.ps1 so the PreLaunchCommand has
         something to run on first launch
      6. Computes SHA-256 of the zip
      7. Uploads the versioned zip to the `minecraft-modpack` public-read
         blob container with cache-immutable headers
      8. Atomically commits `modpack.yml` (audit record) + in-place edits to
         `docker/proxmox/docker-compose.yml` (`PACKWIZ_URL` pinned to current
         origin/main HEAD SHA, `MOTD` pinned to the new version string) on a
         fresh `modpack/v<Version>` branch, opens a PR, and enables
         auto-merge. Portainer GitOps redeploys C2E2 within ~5 min of merge —
         server and client mod-set move in lockstep. We rewrite the compose
         YAML directly rather than a .env file because Portainer's GitOps
         mode polls compose changes and ignores .env files in git.
      9. Uploads `latest.json` AFTER the PR succeeds so audit trail is always
         present before any player can download the new version.

    Authenticates via your existing Azure CLI session (`az login`). You need
    Storage Blob Data Contributor on the container — your user account already
    has this if you can deploy the rest of the stack.

.PARAMETER InstanceName
    Folder name to use for the in-zip instance + as `name=` (with version
    suffix) in the sanitized instance.cfg. Defaults to "Craft to Exile 2".
    When -InstancePath is given, the leaf of that path takes precedence
    and this value is overridden to match.

.PARAMETER Version
    Semantic-ish version string for this publish, e.g. "1.0.0" or "2026.06.04".
    Used as the blob filename suffix and stored in latest.json.

.PARAMETER InstancePath
    Path to the source Prism instance directory to package. Default: the
    staging instance produced by build-instance-from-packwiz.ps1 at
    <RepoRoot>/build/<InstanceName>. Pass this when packaging a
    hand-curated instance from Prism's installed-instances directory
    (testing / hotfix scenarios); omit it for the normal manifest-driven
    flow.

.PARAMETER StorageAccount
    Azure Storage account name. Defaults to stmcminecraftprod.

.PARAMETER Container
    Blob container name. Defaults to minecraft-modpack.

.PARAMETER PrismInstancesDir
    Path to Prism's instances directory. Used as the legacy fallback only
    when neither -InstancePath nor the staging directory exists.
    Defaults to the OS-canonical Prism Launcher instances path:
      Windows: %APPDATA%\PrismLauncher\instances
      Linux:   $HOME/.local/share/PrismLauncher/instances
      macOS:   $HOME/Library/Application Support/PrismLauncher/instances
    The Linux/macOS defaults exist so this script doesn't blow up with a
    misleading "instance not found at \PrismLauncher\..." on a Linux CI
    runner if the staging instance is somehow absent; the CI flow always
    materializes the staging instance via build-instance-from-packwiz.ps1
    first, so the fallback path is never the primary code path.

.PARAMETER UpdateScriptPath
    Path to the player-side `update.ps1` to bundle into the zip at
    <InstanceName>/.negativezone/update.ps1. Defaults to
    docs/assets/update.ps1 from the repo root (the version that gets
    pulled at install/update time via the setup.ps1 one-liner).

.PARAMETER IconPath
    Path to the PNG (or other Prism-supported image format) used as the instance
    icon in the published pack. Defaults to cte2-icon.png next to this script.
    Bundled into the zip at icons/<IconKey>.<ext> and copied to every player's
    %APPDATA%\PrismLauncher\icons\ by setup.ps1.

.PARAMETER IconKey
    Prism iconKey written into the sanitized instance.cfg. Must match the
    bundled icon's basename (without extension). Defaults to "cte2".

.PARAMETER Force
    Allow re-publishing over an existing `modpack/v<Version>` branch on origin.
    Without this, the script refuses if `origin/modpack/v<Version>` already
    exists, to prevent silently stacking a new publish on top of a stale one
    (which is how PR #121 ended up merge-conflicted). With `-Force`, the local
    branch is reset to `origin/main` and pushed with `--force-with-lease`.

.PARAMETER SkipDriftCheck
    Test-publish escape hatch — bypass the origin/main drift check AND the
    server-side coupling steps (compose-rewrite + PR creation + auto-merge).
    Required for E2E-validating the client install flow BEFORE merging the
    packwiz/ changes to origin/main, where the drift check would otherwise
    correctly refuse (the SHA pin in docker-compose.yml resolves against
    origin/main, so unmerged local packwiz/ commits would cause the bundled
    client zip and the server's packwiz fetch to point at different mod sets).

    With -SkipDriftCheck:
      - -Version MUST start with "test-" (case-insensitive) — refuses
        otherwise to prevent accidental misuse on a real publish.
      - The drift check is skipped (loud warning printed).
      - The working-tree-clean check is skipped (you may legitimately have
        in-flight packwiz/ edits during E2E testing).
      - The PR-creation step is skipped entirely (no docker-compose.yml
        mutation, no `git push`, no `gh pr create`, no `gh pr merge --auto`).
      - The manifest is uploaded to `latest-test.json` instead of
        `latest.json` — production setup.ps1 keeps reading the real
        manifest. To install a test publish, set the env var:
          $env:NEGATIVEZONE_MANIFEST_URL = 'https://<account>.blob.core.windows.net/<container>/latest-test.json'
        before running setup.ps1's irm-pipe-iex one-liner.

.EXAMPLE
    ./publish-prism-pack.ps1 -Version 1.0.0

.EXAMPLE
    ./publish-prism-pack.ps1 -InstanceName "C2E2" -Version 2026.06.04

.EXAMPLE
    # Re-publish v1.0.0 after a botched first attempt
    ./publish-prism-pack.ps1 -Version 1.0.0 -Force

.EXAMPLE
    # E2E-test the client install flow before merging packwiz/ changes.
    # Writes the zip + a separate latest-test.json; does not touch the
    # production latest.json or the docker-compose.yml SHA pin.
    ./publish-prism-pack.ps1 -Version test-1 -SkipDriftCheck
#>

[CmdletBinding()]
param(
    [string]$InstanceName = "Craft to Exile 2",
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$InstancePath,
    [string]$StorageAccount = "stmcminecraftprod",
    [string]$Container = "minecraft-modpack",
    [string]$PrismInstancesDir = $(
        if ($IsLinux)   { Join-Path $env:HOME '.local/share/PrismLauncher/instances' }
        elseif ($IsMacOS) { Join-Path $env:HOME 'Library/Application Support/PrismLauncher/instances' }
        else            { "$env:APPDATA\PrismLauncher\instances" }
    ),
    [string]$UpdateScriptPath,
    [string]$IconPath = (Join-Path $PSScriptRoot 'cte2-icon.png'),
    [string]$IconKey = 'cte2',
    [switch]$Force,
    [switch]$SkipDriftCheck
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }

# IconKey becomes a filename on disk (Prism icons dir) and a path inside the
# zip — restrict to safe characters so neither path can be traversed or break
# Prism's lookup.
if ($IconKey -notmatch '^[A-Za-z0-9._-]+$') {
    throw "IconKey must match ^[A-Za-z0-9._-]+$ (got: '$IconKey')."
}

# ─── Test-publish mode validation ───────────────────────────────────────────
# -SkipDriftCheck is the test-publish escape hatch. It MUST be paired with a
# version that starts with "test-" (case-insensitive) so it can never be
# accidentally used to ship a real version to players. The PR-creation step
# is also skipped (see below), and the manifest writes to latest-test.json
# instead of latest.json — production setup.ps1 keeps reading the real one.
if ($SkipDriftCheck) {
    if ($Version -notmatch '^(?i)test-') {
        throw @"
-SkipDriftCheck requires -Version to start with 'test-' (case-insensitive).
Got: '$Version'.
This guardrail prevents the test-publish escape hatch from ever being used
on a real publish — the test version naming convention is the only thing
keeping the test-only manifest (latest-test.json) and the real manifest
(latest.json) from colliding.
Example: -Version test-1   -SkipDriftCheck
"@
    }
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host " TEST-PUBLISH MODE (-SkipDriftCheck)" -ForegroundColor Yellow
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host " - Drift check vs origin/main: SKIPPED" -ForegroundColor Yellow
    Write-Host " - Working-tree-clean check:   SKIPPED" -ForegroundColor Yellow
    Write-Host " - docker-compose.yml rewrite: SKIPPED (no server-side mutation)" -ForegroundColor Yellow
    Write-Host " - git push + PR + auto-merge: SKIPPED" -ForegroundColor Yellow
    Write-Host " - Manifest will be uploaded to 'latest-test.json' (NOT latest.json)" -ForegroundColor Yellow
    Write-Host " - Production setup.ps1 will keep reading latest.json untouched" -ForegroundColor Yellow
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host ""
}

# ─── Preflight ──────────────────────────────────────────────────────────────
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') is required. Install from https://aka.ms/installazurecli"
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') is required. Install from https://cli.github.com/"
}

if (-not (Test-Path -LiteralPath $IconPath)) {
    throw "Icon file not found at: $IconPath`nPass -IconPath to override."
}
$iconFile = Get-Item -LiteralPath $IconPath

# Resolve repo root early — we need it for the staging-instance default path
# AND for the post-upload .env bump that pins PACKWIZ_COMMIT_SHA. Resolve
# from $PSScriptRoot rather than $PWD so the caller can invoke this script
# from anywhere on disk.
Push-Location $PSScriptRoot
try {
    $repoRoot = (git rev-parse --show-toplevel | Out-String).Trim()
} finally {
    Pop-Location
}
if (-not $repoRoot) {
    throw "Could not resolve repo root via 'git rev-parse --show-toplevel'."
}

# ─── CI vs local drift detection ────────────────────────────────────────────
# In CI (GitHub Actions sets $env:CI='true'), actions/checkout produces a
# clean tree from origin/main, so the local-divergence checks below are
# vacuous and just add noise. In local runs, drift between the working
# packwiz/ tree and origin/main would cause the bundled client zip (built
# from disk) to diverge from the SHA pin written into docker-compose.yml
# (which the script later resolves via `git rev-parse HEAD` after a fresh
# `git checkout -B publishBranch origin/main`). Detect drift early and
# fail with clear remediation so a botched local publish never makes it
# to the blob upload or PR-open steps.
if ($env:CI -eq 'true') {
    Write-Step "CI mode detected (`$env:CI='true'`); skipping local drift checks."
} elseif ($SkipDriftCheck) {
    Write-Step "Test-publish mode (-SkipDriftCheck); skipping local drift checks."
} else {
    Write-Step "Local mode; checking packwiz/ for drift vs origin/main..."

    Push-Location $repoRoot
    try {
        # 1. No uncommitted packwiz/ changes (working tree or index).
        $dirty = (git status --porcelain -- packwiz/ | Out-String).TrimEnd()
        if ($dirty) {
            Write-Host ""
            Write-Host "Local repo has uncommitted packwiz/ changes:" -ForegroundColor Yellow
            $dirty -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
            Write-Host ""
            Write-Host "Commit and push them to origin/main first (or stash) before publishing." -ForegroundColor Yellow
            Write-Host "Otherwise the SHA pin in docker-compose.yml will diverge from the bundled client zip." -ForegroundColor Yellow
            Write-Error "Uncommitted packwiz/ changes detected. Aborting."
            exit 1
        }

        # 2. Local packwiz/ matches origin/main's packwiz/.
        # Use --stat (not --quiet) because $PSNativeCommandUseErrorActionPreference
        # is on and --quiet returning exit 1 on diff would throw before we can
        # report the diff cleanly. --stat always exits 0 on success.
        git fetch origin main --quiet | Out-Null
        $diffStat = (git diff --stat HEAD origin/main -- packwiz/ | Out-String).TrimEnd()
        if ($diffStat) {
            Write-Host ""
            Write-Host "Local packwiz/ tree differs from origin/main:" -ForegroundColor Yellow
            $diffStat -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
            Write-Host ""
            Write-Host "Push your packwiz/ commits to origin/main (via PR + merge) before publishing." -ForegroundColor Yellow
            Write-Host "The SHA pin written into docker-compose.yml resolves against origin/main, so" -ForegroundColor Yellow
            Write-Host "any unmerged local commits would not be visible to Portainer's git fetch." -ForegroundColor Yellow
            Write-Error "Local packwiz/ tree diverges from origin/main. Aborting."
            exit 1
        }

        Write-Ok "packwiz/ tree matches origin/main"
    } finally {
        Pop-Location
    }
}

# ─── Instance path resolution ───────────────────────────────────────────────
# Preferred source: the staging instance materialized by
# build-instance-from-packwiz.ps1. Falls back to a hand-curated instance in
# the admin's local Prism install for hotfix / one-off publishes (with a
# loud warning so the source-of-truth status is obvious in the log).
$stagingInstance = Join-Path $repoRoot ('build/' + $InstanceName)
if (-not $InstancePath) {
    if (Test-Path -LiteralPath $stagingInstance) {
        $InstancePath = $stagingInstance
        Write-Step "Using staging instance from build-instance-from-packwiz.ps1: $InstancePath"
    } else {
        $InstancePath = Join-Path $PrismInstancesDir $InstanceName
        Write-Host "    [warn] No staging instance at '$stagingInstance' — falling back to local Prism instance at '$InstancePath'." -ForegroundColor Yellow
        Write-Host "    [warn] Run infra/azure/scripts/build-instance-from-packwiz.ps1 first for the manifest-driven flow." -ForegroundColor Yellow
    }
}

if (-not (Test-Path -LiteralPath $InstancePath)) {
    throw "Instance not found at: $InstancePath`nPass -InstancePath, or run build-instance-from-packwiz.ps1 to materialize the staging instance."
}

# If the leaf of -InstancePath doesn't match -InstanceName, prefer the leaf
# (it dictates the in-zip folder name, which setup.ps1 maps to the player's
# %APPDATA%\PrismLauncher\instances\<leaf>\). Bail loudly if a non-default
# -InstanceName was passed and conflicts — silent rename is too magical.
$instanceLeaf = Split-Path -Leaf $InstancePath
if ($instanceLeaf -ne $InstanceName) {
    if ($PSBoundParameters.ContainsKey('InstanceName')) {
        throw "InstancePath leaf '$instanceLeaf' does not match -InstanceName '$InstanceName'. Pass one or the other, not both."
    }
    Write-Host "    [info] Using InstanceName from -InstancePath leaf: '$instanceLeaf'" -ForegroundColor Cyan
    $InstanceName = $instanceLeaf
}

$instancePath = $InstancePath

if (-not (Test-Path (Join-Path $instancePath 'instance.cfg'))) {
    throw "Path '$instancePath' doesn't look like a Prism instance (no instance.cfg)."
}

# ─── update.ps1 resolution ──────────────────────────────────────────────────
if (-not $UpdateScriptPath) {
    $UpdateScriptPath = Join-Path $repoRoot 'docs/assets/update.ps1'
}
if (-not (Test-Path -LiteralPath $UpdateScriptPath)) {
    throw "update.ps1 not found at: $UpdateScriptPath`nPass -UpdateScriptPath to override."
}
$UpdateScriptPath = (Resolve-Path -LiteralPath $UpdateScriptPath).Path

# ─── Git preflight ─────────────────────────────────────────────────────────
# Catch the two failure modes that produced PR #121's merge conflict:
#   1. Working tree dirty (would mix unrelated edits into the auto-PR).
#   2. `origin/modpack/v<Version>` already exists (we'd silently stack a new
#      commit on a stale publish branch, or two parallel publishes would
#      clobber each other).
# Both fail fast, BEFORE the expensive zip + blob upload, so a bad git state
# doesn't waste a multi-minute publish.
$publishBranch = "modpack/v$Version"

Push-Location $repoRoot
try {
    if ($SkipDriftCheck) {
        Write-Step "Test-publish mode; skipping working-tree-clean check (in-flight edits OK)."
    } else {
        $dirty = (git status --porcelain) -join "`n"
        if ($dirty) {
            throw "Working tree at '$repoRoot' is not clean. Commit or stash these changes before publishing:`n$dirty"
        }
    }

    Write-Step "Fetching origin (refs + prune)"
    git fetch origin --prune

    $expectedRemoteSha = ''
    if ($SkipDriftCheck) {
        Write-Step "Test-publish mode; skipping origin/$publishBranch existence check (no PR will be opened)."
    } else {
        $remoteRef = (git for-each-ref --format='%(refname)' "refs/remotes/origin/$publishBranch" | Out-String).Trim()
        if ($remoteRef) {
            # Capture the exact SHA we observed at preflight time so we can pass an
            # explicit lease to `git push --force-with-lease=<ref>:<sha>` later. The
            # default lease form (no `:<sha>`) trusts the local remote-tracking ref,
            # which is unsafe here because there's a multi-minute window (zip + blob
            # upload + git/PR) during which a background tool (VS Code, GCM) could
            # auto-fetch and silently advance the tracking ref.
            $expectedRemoteSha = (git rev-parse $remoteRef | Out-String).Trim()
            if (-not $Force) {
                $existingPrUrl = ''
                try {
                    $existingPrUrl = (gh pr list --head $publishBranch --base main --state open --json url --jq '.[0].url' | Out-String).Trim()
                } catch {
                    # gh may fail (auth, rate limit) — don't block the user from seeing the real error.
                }
                $hint = if ($existingPrUrl) { "Existing open PR: $existingPrUrl" } else { "(No open PR found for this branch.)" }
                throw @"
Remote branch 'origin/$publishBranch' already exists.
$hint
Pick a different -Version, or re-run with -Force to overwrite it (force-push + reuse the PR).
"@
            }
            Write-Host "    [warn] origin/$publishBranch already exists at $expectedRemoteSha; -Force will overwrite it" -ForegroundColor Yellow
        }
    }
} finally {
    Pop-Location
}

# Blob preflight: the versioned zip lives at an immutable URL (Cache-Control
# headers tell CDNs it never changes), so overwriting one with different bytes
# is a player-visible correctness hazard. Refuse without -Force.
#
# Test-publish mode (-SkipDriftCheck) loosens this so iterative test runs at
# the same -Version (e.g. -Version test-1 over and over) don't need -Force.
# Safe: test blobs are only consumed by boxes that have set the
# NEGATIVEZONE_MANIFEST_URL override, never by real players.
Write-Step "Checking for existing blob 'c2e2-v$Version.zip'"
$blobExistsJson = (az storage blob exists `
    --account-name $StorageAccount `
    --container-name $Container `
    --name "c2e2-v$Version.zip" `
    --auth-mode login `
    --output json | Out-String).Trim()
$blobAlreadyExists = ($blobExistsJson | ConvertFrom-Json).exists
if ($blobAlreadyExists) {
    if ($SkipDriftCheck) {
        Write-Host "    [info] Test blob 'c2e2-v$Version.zip' already exists; will overwrite (test-publish mode)" -ForegroundColor Yellow
    } elseif (-not $Force) {
        throw "Blob 'c2e2-v$Version.zip' already exists in '$StorageAccount/$Container'. Pick a new -Version or re-run with -Force to overwrite."
    } else {
        Write-Host "    [warn] Blob 'c2e2-v$Version.zip' already exists; -Force will overwrite it" -ForegroundColor Yellow
    }
}

# ─── Export ────────────────────────────────────────────────────────────────
$blobName = "c2e2-v$Version.zip"
$tempZip  = Join-Path $env:TEMP $blobName

Write-Step "Exporting Prism instance '$InstanceName' -> $tempZip"
if (Test-Path $tempZip) { Remove-Item $tempZip -Force }

# Zip the instance folder but exclude user-specific files that shouldn't
# ship to other players. We keep mods/, config/, resourcepacks/, shaderpacks/,
# instance.cfg (sanitized — see Sanitize-InstanceCfg below), mmc-pack.json,
# and servers.dat (pre-configured).
$excludePatterns = @(
    '*/saves/*'
    '*/logs/*'
    '*/crash-reports/*'
    '*/screenshots/*'
    '*/backups/*'
    '*/options.txt'
    '*/optionsof.txt'
    '*/optionsshaders.txt'
    '*/realms_persistence.json'
    '*/usercache.json'
    '*/usernamecache.json'
    '*/.lck'
)

# Compress-Archive doesn't support exclusions, so we use .NET ZipFile directly.
Add-Type -AssemblyName System.IO.Compression.FileSystem

function ShouldExclude([string]$relativePath) {
    $normalized = $relativePath -replace '\\', '/'
    foreach ($pattern in $excludePatterns) {
        if ($normalized -like $pattern) { return $true }
    }
    return $false
}

# Removes machine-specific Java fields, user play-time, the [UI] section, and
# pins memory + iconKey to known-good defaults so players don't have to touch
# Prism's Java/memory settings or set the icon after import. iconKey is forced
# to the bundled icon so the published pack is reproducible regardless of what
# the admin's local Prism instance happens to have set.
#
# Also wires up the PreLaunchCommand hook so the bundled .negativezone/update.ps1
# runs on every Prism launch, giving us zero-action client auto-update against
# Azure Blob's latest.json manifest.
function Get-SanitizedInstanceCfg(
    [string]$path,
    [string]$iconKey,
    [string]$instanceName,
    [string]$version
) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    # Normalize line endings to CRLF (Prism writes CRLF on Windows).
    $lines = $raw -split "\r?\n"

    # Fields whose values are tied to the admin's local JDK install.
    $stripExact = @(
        'JavaPath', 'JavaSignature', 'JavaArchitecture', 'JavaRealArchitecture',
        'JavaVendor', 'JavaVersion',
        'lastLaunchTime', 'lastTimePlayed', 'totalTimePlayed',
        'LastLaunchTime', 'LastTimePlayed', 'TotalTimePlayed',
        'ExportAuthor', 'ExportName', 'ExportSummary', 'ExportVersion',
        'ExportOptionalFiles'
    )

    # Single-quoted PS string keeps `$INST_DIR` as a literal — Prism does
    # the variable substitution at launch time, not PowerShell now. The outer
    # double-quotes are part of the command value: Prism uses QProcess::splitCommand
    # to parse the string, which respects double-quoted segments containing spaces
    # (e.g. C:\Users\Jane Doe\AppData\Roaming\PrismLauncher\instances\...).
    $preLaunchCommand = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INST_DIR\.negativezone\update.ps1"'

    # Fields whose values we override to a known-good default. Order: existing
    # lines get rewritten in place; missing fields get appended to [General].
    # 8192 MB matches C2E2's recommended ceiling — players on 8 GB-total
    # systems should lower it to 4096 in Prism after install.
    #
    # name= carries the version suffix so players see the live version in
    # Prism's instance grid. update.ps1 patches this line on every swap so
    # subsequent updates keep the label fresh (one-launch lag is acceptable).
    #
    # OverrideCommands + PreLaunchCommand wire up the auto-update hook. The
    # hook is fail-open on network errors (lets the game launch when offline)
    # and fail-closed on SHA mismatch (blocks corrupted installs).
    $overrides = [ordered]@{
        'AutomaticJava'         = 'true'
        'OverrideJavaLocation'  = 'false'
        'OverrideMemory'        = 'true'
        'MinMemAlloc'           = '512'
        'MaxMemAlloc'           = '8192'
        'iconKey'               = $iconKey
        'name'                  = "$instanceName v$version"
        'OverrideCommands'      = 'true'
        'PreLaunchCommand'      = $preLaunchCommand
    }

    $out = New-Object System.Collections.Generic.List[string]
    $inUiSection = $false
    $seenKeys = @{}

    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd()

        # Drop the entire [UI] section — window state, column widths, etc. are
        # user-specific and would otherwise clobber the player's layout on
        # every modpack update.
        if ($trimmed -match '^\[UI\]\s*$') { $inUiSection = $true; continue }
        if ($inUiSection -and $trimmed -match '^\[.+\]\s*$') { $inUiSection = $false }
        if ($inUiSection) { continue }

        if ($trimmed -match '^([A-Za-z0-9_]+)=(.*)$') {
            $key = $matches[1]

            if ($stripExact -contains $key) { continue }

            if ($overrides.Contains($key)) {
                $out.Add("$key=$($overrides[$key])")
                $seenKeys[$key] = $true
                continue
            }
        }

        $out.Add($trimmed)
    }

    # Append any override keys that weren't already present (they'll land in
    # whatever section is current, but [General] is always first in Prism's
    # cfg so any missing key sits in [General], which is what we want).
    foreach ($key in $overrides.Keys) {
        if (-not $seenKeys.ContainsKey($key)) {
            $out.Insert(1, "$key=$($overrides[$key])")
        }
    }

    return ($out -join "`r`n")
}

$instanceCfgPath = Join-Path $instancePath 'instance.cfg'
$sanitizedCfg = Get-SanitizedInstanceCfg $instanceCfgPath $IconKey $InstanceName $Version

$zip = [System.IO.Compression.ZipFile]::Open($tempZip, 'Create')
try {
    $basePath = Split-Path $instancePath -Parent
    $files = Get-ChildItem -Path $instancePath -Recurse -File
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($basePath.Length + 1)
        if (ShouldExclude $relativePath) { continue }
        $entryName = $relativePath -replace '\\', '/'

        if ($file.FullName -eq $instanceCfgPath) {
            # Write the sanitized instance.cfg in place of the on-disk one so
            # we don't mutate the admin's local Prism state.
            $entry = $zip.CreateEntry($entryName, 'Optimal')
            $writer = New-Object System.IO.StreamWriter($entry.Open(), [System.Text.UTF8Encoding]::new($false))
            try { $writer.Write($sanitizedCfg) } finally { $writer.Dispose() }
        } else {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.FullName, $entryName, 'Optimal') | Out-Null
        }
    }

    # Bundle the icon at icons/<IconKey>.<ext> — basename MUST equal the
    # iconKey we wrote into instance.cfg above, or Prism won't find it after
    # setup.ps1 copies icons/* to %APPDATA%\PrismLauncher\icons\.
    $iconEntry = "icons/$IconKey$($iconFile.Extension.ToLower())"
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, $iconFile.FullName, $iconEntry, 'Optimal') | Out-Null
    Write-Ok "Bundled icon: $($iconFile.Name) -> $iconEntry"

    # Bundle the player-side update.ps1 at <InstanceName>/.negativezone/update.ps1
    # so Prism's PreLaunchCommand (written into the sanitized instance.cfg
    # above) can invoke it. Each published zip embeds the matching update.ps1
    # — admins can't roll back the script without also re-publishing the
    # client zip, which is fine because update.ps1 is small + stable.
    $updateEntry = "$InstanceName/.negativezone/update.ps1"
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, $UpdateScriptPath, $updateEntry, 'Optimal') | Out-Null
    Write-Ok "Bundled update.ps1 -> $updateEntry"
} finally {
    $zip.Dispose()
}

$sizeMb = [math]::Round((Get-Item $tempZip).Length / 1MB, 1)
Write-Ok "Zip size: ${sizeMb} MB"

# ─── SHA-256 ───────────────────────────────────────────────────────────────
Write-Step "Computing SHA-256"
$sha = (Get-FileHash $tempZip -Algorithm SHA256).Hash.ToLower()
Write-Ok "sha256 = $sha"

# ─── Upload ────────────────────────────────────────────────────────────────
# --overwrite is gated by -Force OR -SkipDriftCheck: the blob preflight
# already refused if the blob exists without -Force, so this is defense-in-depth
# against a concurrent publisher creating the blob between preflight and upload.
# Test-publish mode always overwrites so iterative runs at the same test
# version don't need -Force.
$overwriteFlag = if ($Force -or $SkipDriftCheck) { 'true' } else { 'false' }
Write-Step "Uploading to $StorageAccount/$Container/$blobName (overwrite=$overwriteFlag)"
az storage blob upload `
    --account-name $StorageAccount `
    --container-name $Container `
    --name $blobName `
    --file $tempZip `
    --auth-mode login `
    --overwrite $overwriteFlag `
    --content-cache-control "public, max-age=2592000, immutable" `
    --output none

# ─── Build latest.json manifest (upload happens AFTER git/PR succeeds) ─────
# Why upload last: latest.json is what setup.ps1 reads to fetch the modpack.
# If we updated it before the git push succeeded and the push then failed,
# players would download a version with no corresponding committed modpack.yml
# (no audit trail). Building it here keeps $manifest in scope for the upload
# step below, but the actual `az storage blob upload` is deferred until after
# the PR is opened.
Write-Step "Building latest.json manifest"
$manifest = [ordered]@{
    version    = $Version
    blob       = $blobName
    url        = "https://$StorageAccount.blob.core.windows.net/$Container/$blobName"
    sha256     = $sha
    sizeBytes  = (Get-Item $tempZip).Length
    instance   = $InstanceName
    publishedAt = (Get-Date).ToUniversalTime().ToString('o')
}

$manifestPath = Join-Path $env:TEMP 'latest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8

# ─── Update modpack.yml + .env + open PR ───────────────────────────────────
# Skipped in test-publish mode — the SHA pin in docker-compose.yml would
# resolve against origin/main, which by definition doesn't have the local
# packwiz/ changes the test publish is validating. Writing it would either
# fail loudly (if packwiz/ on origin/main has different content) or worse,
# silently couple the test publish to a wrong server snapshot. Cleaner to
# skip the whole step.
if ($SkipDriftCheck) {
    Write-Step "Test-publish mode; skipping modpack.yml + docker-compose.yml rewrite + PR creation."
} else {
    Write-Step "Creating branch '$publishBranch' from origin/main"
    Push-Location $repoRoot
    try {
        # ALWAYS branch from fresh origin/main — never from local HEAD. The old
        # `if (currentBranch -eq 'main') { git checkout -b ... }` was the root
        # cause of PR #121's conflict: re-running the script from a leftover
        # publish branch silently stacked the new commit on stale history.
        git checkout -B $publishBranch "origin/main"

        # Capture the SHA we just checked out — this is the packwiz/ snapshot
        # the staging instance was materialized from (build-instance-from-packwiz
        # reads the working tree, and the working-tree-clean preflight above
        # ensured local packwiz/ matches origin/main). Pinning .env's
        # PACKWIZ_COMMIT_SHA to this value is what locks the server side to
        # exactly the manifest the client zip ships.
        $packwizSha = (git rev-parse HEAD | Out-String).Trim()
        if ($packwizSha -notmatch '^[0-9a-f]{40}$') {
            throw "Unexpected SHA from 'git rev-parse HEAD': '$packwizSha'"
        }

        # Write modpack.yml AFTER the branch reset so the new content survives.
        $modpackYml = Join-Path $repoRoot 'modpack.yml'
        $publishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $yamlContent = @"
# Central modpack version record — updated by publish-prism-pack.ps1
# This provides a committed, auditable record of the currently published pack.
version: "$Version"
blob: $blobName
sha256: $sha
url: https://$StorageAccount.blob.core.windows.net/$Container/$blobName
instance: $InstanceName
publishedAt: "$publishedAt"
"@
        Set-Content -Path $modpackYml -Value $yamlContent -Encoding UTF8

        # Atomic SHA + version bump for the C2E2 server: by rewriting the two
        # tracked literal values in docker/proxmox/docker-compose.yml in the same
        # commit as modpack.yml, Portainer GitOps's next 5-min poll will redeploy
        # the server with the new PACK_VERSION (visible in MOTD) and the new
        # PACKWIZ_COMMIT_SHA (pinning the server's mod set to the same snapshot
        # that's in the client zip just uploaded). Players' next Prism launch
        # fetches the new client zip via PreLaunchCommand, so server + client
        # move together — no kicked-by-mod-mismatch window.
        #
        # We rewrite the compose YAML directly (not a .env file) because
        # Portainer CE's GitOps mode polls the compose file and triggers
        # redeploy on content change; Portainer ignores .env files in git
        # (per project convention, all UI-managed env vars live in Portainer's
        # stack environment UI). Inline literals = single source of truth.
        $composeFile = Join-Path $repoRoot 'docker/proxmox/docker-compose.yml'
        if (-not (Test-Path -LiteralPath $composeFile)) {
            throw "Expected $composeFile to exist. Cannot bump PACK_VERSION / PACKWIZ_COMMIT_SHA."
        }
        $composeContent = Get-Content -Raw -LiteralPath $composeFile -Encoding UTF8

        # Pin the packwiz manifest URL to the SHA we just captured. The pattern
        # is anchored on the github.com path so we don't accidentally rewrite
        # any unrelated URL that happens to look like a sha. Fail loudly if
        # the line isn't found in the expected shape — a silently-no-op
        # publish would let server and client drift.
        $urlRegex = '(?m)^(\s*PACKWIZ_URL:\s*"https://raw\.githubusercontent\.com/camcast3/MinecraftInfra/)([^/"]+)(/packwiz/pack\.toml")\s*$'
        $urlMatches = [regex]::Matches($composeContent, $urlRegex)
        if ($urlMatches.Count -ne 1) {
            throw ("Expected exactly 1 PACKWIZ_URL line in $composeFile (matched {0}). " +
                   "Has the line been manually edited?") -f $urlMatches.Count
        }
        $composeContent = [regex]::Replace($composeContent, $urlRegex, "`${1}$packwizSha`${3}")

        # Pin the MOTD version. Same one-match guard.
        $motdRegex = '(?m)^(\s*MOTD:\s*"Craft to Exile 2 v)([^"]+)(")\s*$'
        $motdMatches = [regex]::Matches($composeContent, $motdRegex)
        if ($motdMatches.Count -ne 1) {
            throw ("Expected exactly 1 MOTD line in $composeFile (matched {0}). " +
                   "Has the line been manually edited?") -f $motdMatches.Count
        }
        $composeContent = [regex]::Replace($composeContent, $motdRegex, "`${1}$Version`${3}")

        # Write back with UTF-8 no-BOM, original line endings preserved (Get-Content
        # -Raw keeps the existing `r`n vs `n; Set-Content -NoNewline writes the
        # buffer verbatim).
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($composeFile, $composeContent, $utf8NoBom)
        Write-Ok "Rewrote docker/proxmox/docker-compose.yml: PACKWIZ_URL pinned to $packwizSha, MOTD pinned to v$Version"

        git add modpack.yml 'docker/proxmox/docker-compose.yml'
        git commit -m "chore(modpack): publish v$Version`n`nsha256: $sha`npackwiz_sha: $packwizSha"

        Write-Step "Pushing $publishBranch to origin"
        if ($Force -and $expectedRemoteSha) {
            # Explicit lease tied to the SHA we observed at preflight time. Refuses
            # if anything (concurrent publisher OR background auto-fetch) moved the
            # branch since then. Safer than the default lease form, which only
            # checks the local remote-tracking ref.
            git push "--force-with-lease=refs/heads/${publishBranch}:${expectedRemoteSha}" -u origin HEAD
        } else {
            # Branch didn't exist at preflight time. A plain push will fail loudly
            # if a concurrent publisher created the branch in the meantime — git
            # refuses to create a branch that already exists on the remote.
            git push -u origin HEAD
        }

        Write-Step "Opening pull request"
        $prBody = @"
Automated modpack publish.

- **Version:** $Version
- **SHA-256:** ``$sha``
- **Size:** ${sizeMb} MB
- **Published:** $publishedAt
- **packwiz SHA pin:** ``$packwizSha``

This PR atomically bumps:
- ``modpack.yml`` — the published-version audit record consumed by ``setup.ps1``.
- ``docker/proxmox/docker-compose.yml`` — ``PACKWIZ_URL`` pinned to the new
  packwiz SHA, ``MOTD`` pinned to the new version. Portainer GitOps redeploys
  C2E2 within ~5 min of merge, pulling the same packwiz snapshot that's bundled
  in the client zip above. Server + client move in lockstep.
"@
        $prUrl = $null
        try {
            $prUrl = (gh pr create `
                --title "chore(modpack): publish v$Version" `
                --body $prBody `
                --base main `
                --head $publishBranch | Out-String).Trim()
        } catch {
            # Most likely cause: PR already exists for this head (re-publish via -Force).
            # Reuse the existing PR's URL instead of failing.
            $prUrl = (gh pr list --head $publishBranch --base main --state open --json url --jq '.[0].url' | Out-String).Trim()
            if (-not $prUrl) { throw }
            Write-Host "    [info] PR already exists for $publishBranch, reusing it" -ForegroundColor Yellow
        }
        Write-Ok "PR: $prUrl"

        # Enable auto-merge so the PR squash-merges as soon as required checks pass.
        # Shrinks the window where a second publish could race and collide.
        # Non-fatal: if the repo doesn't have auto-merge enabled, just warn and move on.
        try {
            gh pr merge $prUrl --auto --squash --delete-branch | Out-Null
            Write-Ok "Auto-merge enabled (squash + delete branch)"
        } catch {
            Write-Host "    [warn] Could not enable auto-merge (is it enabled on the repo?). Merge the PR manually." -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
    }
}

# ─── Publish latest.json (LAST — only after the audit-trail PR exists) ─────
# Up until this point, no player-visible state has been updated: the versioned
# zip is uploaded but unreferenced (latest.json still points at the previous
# version). Only after the git push + PR succeed do we flip latest.json to
# advertise the new version. This guarantees that players never see a version
# without a corresponding committed modpack.yml.
#
# Test-publish mode writes to latest-test.json instead so production setup.ps1
# (which reads latest.json) is untouched. Set $env:NEGATIVEZONE_MANIFEST_URL
# on a test box to point setup.ps1 at the test manifest.
$manifestBlobName = if ($SkipDriftCheck) { 'latest-test.json' } else { 'latest.json' }
Write-Step "Uploading $manifestBlobName"
az storage blob upload `
    --account-name $StorageAccount `
    --container-name $Container `
    --name $manifestBlobName `
    --file $manifestPath `
    --auth-mode login `
    --overwrite true `
    --content-type "application/json" `
    --content-cache-control "no-cache" `
    --output none

# ─── Cleanup ───────────────────────────────────────────────────────────────
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($SkipDriftCheck) {
    Write-Host "Test-publish complete (production latest.json untouched)." -ForegroundColor Green
    Write-Host "  Test manifest: https://$StorageAccount.blob.core.windows.net/$Container/$manifestBlobName"
    Write-Host "  Test zip:      https://$StorageAccount.blob.core.windows.net/$Container/$blobName"
    Write-Host ""
    Write-Host "To install this test publish, set the manifest URL override before running setup.ps1:" -ForegroundColor Cyan
    Write-Host "  `$env:NEGATIVEZONE_MANIFEST_URL = 'https://$StorageAccount.blob.core.windows.net/$Container/$manifestBlobName'" -ForegroundColor Cyan
    Write-Host "  irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 | iex" -ForegroundColor Cyan
} else {
    Write-Host "Published successfully." -ForegroundColor Green
    Write-Host "  Manifest: https://$StorageAccount.blob.core.windows.net/$Container/$manifestBlobName"
    Write-Host "  Zip:      https://$StorageAccount.blob.core.windows.net/$Container/$blobName"
}
Write-Host ""
