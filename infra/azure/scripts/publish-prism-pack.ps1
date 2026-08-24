#requires -Version 7.0
<#
.SYNOPSIS
    Export a Prism Launcher instance and publish it to Azure Blob storage so
    nz setup can pull it in ~2 min instead of waiting through CurseForge.

    Sanitizes instance.cfg (strips local Java fields, forces AutomaticJava,
    pins memory + iconKey + version label, and disables source-instance custom
    commands). Bundles the icon and preservation manifest; nz setup installs
    nz.exe and writes the production launch/backup hooks transactionally.
    Uploads a versioned zip and manifest with immutable cache headers.
    Atomically commits modpack.yml + rewrites
    docker/proxmox/docker-compose.yml (PACKWIZ_URL pinned to current HEAD
    SHA, MOTD pinned to new version) + docker/azure/velocity/velocity.toml.tmpl
    (Velocity fallback MOTD pinned to new version) on a fresh
    modpack/v<Version> branch, then opens a PR with auto-merge. Portainer GitOps
    redeploys C2E2 within ~5 min. Stable client and launch-time pointers are
    promoted separately only after merge and the public server health gate.
    The immutable manifest includes a packwizUrl pinned to the
    same commit SHA as the server PACKWIZ_URL so client-side packwiz delta
    updates use the matching manifest. Compose YAML is rewritten directly
    (not .env) because Portainer ignores .env files in git.

    Authenticates via existing `az login`. Requires Storage Blob Data
    Contributor on the container.

.PARAMETER InstanceName
    In-zip folder name + `name=` (with version suffix) for sanitized
    instance.cfg. Default "Craft to Exile 2". When -InstancePath is given,
    its leaf wins.

.PARAMETER Version
    Semantic-ish version string, e.g. "1.0.0". Used as blob filename suffix
    and in latest.json.

.PARAMETER InstancePath
    Source Prism instance to package. Default: staging instance at
    <RepoRoot>/build/<InstanceName> from build-instance-from-packwiz.ps1.
    Pass this for hand-curated hotfix instances.

.PARAMETER StorageAccount
    Azure Storage account. Default stmcminecraftprod.

.PARAMETER Container
    Blob container. Default minecraft-modpack.

.PARAMETER PrismInstancesDir
    Legacy fallback only — used when neither -InstancePath nor staging dir
    exists. OS-canonical Prism instances path by default.

.PARAMETER IconPath
    Instance icon. Default cte2-icon.png next to this script. Bundled at
    icons/<IconKey>.<ext>.

.PARAMETER IconKey
    Prism iconKey written into sanitized instance.cfg. Must match bundled
    icon basename. Default "cte2".

.PARAMETER Force
    Allow re-publishing over an existing `modpack/v<Version>` branch on
    origin. Without this, the script refuses (PR #121 root cause). With
    -Force, local branch resets to origin/main and force-pushes with lease.
    Also the recovery mode for resuming a publish that failed after immutable
    assets were staged. Existing assets are reused only when their checksums
    and compatibility metadata match; immutable production assets are never
    overwritten.

.PARAMETER SkipDriftCheck
    Test-publish escape hatch — bypasses drift check AND server-side
    coupling (compose-rewrite + PR + auto-merge). -Version MUST start
    with "test-". Manifest goes to latest-test.json, not latest.json.
    Production nz clients stay on production unless they set

.PARAMETER AllowDowngrade
    Set "allowDowngrade": true in the published manifest so the player-side
    nz update / nz setup commands will accept rolling back from a newer installed
    build to this older -Version. Default is omitted (false) — the
    player-side guard refuses downgrades by default to defend against a
    typo'd manifest version silently rolling everyone back. Use this flag
    when shipping an intentional emergency rollback.
    $env:NEGATIVEZONE_MANIFEST_URL.

.EXAMPLE
    ./publish-prism-pack.ps1 -Version 1.0.0

.EXAMPLE
    # Re-publish v1.0.0 after a botched first attempt
    ./publish-prism-pack.ps1 -Version 1.0.0 -Force

.EXAMPLE
    # E2E-test the client install flow without touching production
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
    [string]$UserPrefsPath,
    [string]$IconPath = (Join-Path $PSScriptRoot 'cte2-icon.png'),
    [string]$IconKey = 'cte2',
    [switch]$Force,
    [switch]$SkipDriftCheck,
    [switch]$AllowDowngrade,
    # ─── Local-publish mode ──────────────────────────────────────────────────
    # When -LocalOutDir is set, the script runs the IDENTICAL packaging path
    # (sanitize instance.cfg, bundle icon + preserve-list.json, apply
    # exclusions, structural mod-JAR sanity check,
    # compute SHA-256, build the manifest) but writes the versioned zip and a
    # latest.json into -LocalOutDir instead of uploading to Azure. ALL Azure,
    # git, PR, and docker-compose side effects are skipped. This is how you
    # replicate a real publish locally and target arbitrary local version tags
    # (e.g. for test-upgrade-real.ps1's loopback server) without touching
    # production storage or origin/main.
    [string]$LocalOutDir,
    # Base URL the local manifest's `url` points at (so `nz setup` can fetch the
    # zip over http). Defaults to a loopback server on port 8788. The zip is
    # served as <LocalBaseUrl>/<blobName>.
    [string]$LocalBaseUrl = 'http://127.0.0.1:8788'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }

# ─── Local-publish mode setup ───────────────────────────────────────────────
# $LocalMode gates every Azure / git / PR side effect below to a no-op so the
# same packaging code produces a local zip + manifest. Production publishes
# (no -LocalOutDir) are unaffected — every guard is false.
$LocalMode = [bool]$LocalOutDir
if ($LocalMode) {
    if ($SkipDriftCheck) {
        throw "-LocalOutDir and -SkipDriftCheck are mutually exclusive (LocalOutDir is already fully local; it never touches Azure or git)."
    }
    New-Item -ItemType Directory -Path $LocalOutDir -Force | Out-Null
    $LocalOutDir = (Resolve-Path -LiteralPath $LocalOutDir).Path
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Magenta
    Write-Host " LOCAL-PUBLISH MODE (-LocalOutDir)" -ForegroundColor Magenta
    Write-Host "==============================================================" -ForegroundColor Magenta
    Write-Host " - Same packaging as a real publish (sanitize + bundle + verify)" -ForegroundColor Magenta
    Write-Host " - az upload / git / PR / docker-compose rewrite: SKIPPED" -ForegroundColor Magenta
    Write-Host " - Output dir : $LocalOutDir" -ForegroundColor Magenta
    Write-Host " - Manifest url: $LocalBaseUrl/c2e2-v$Version.zip" -ForegroundColor Magenta
    Write-Host "==============================================================" -ForegroundColor Magenta
    Write-Host ""
}

# IconKey becomes a filename on disk + an in-zip path — restrict to safe
# chars to prevent path traversal or breaking Prism's lookup.
if ($IconKey -notmatch '^[A-Za-z0-9._-]+$') {
    throw "IconKey must match ^[A-Za-z0-9._-]+$ (got: '$IconKey')."
}

# Test-publish guardrail: -SkipDriftCheck MUST pair with -Version 'test-...'
# so the escape hatch can never accidentally ship a real version.
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
    Write-Host " - Production nz clients will keep reading latest.json untouched" -ForegroundColor Yellow
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host ""
}

# ─── Preflight ──────────────────────────────────────────────────────────────
if (-not $LocalMode) {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') is required. Install from https://aka.ms/installazurecli"
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI ('gh') is required. Install from https://cli.github.com/"
    }
}

if (-not (Test-Path -LiteralPath $IconPath)) {
    throw "Icon file not found at: $IconPath`nPass -IconPath to override."
}
$iconFile = Get-Item -LiteralPath $IconPath

# Resolve from $PSScriptRoot (not $PWD) so the caller can invoke this
# script from anywhere on disk.
Push-Location $PSScriptRoot
try {
    $repoRoot = (git rev-parse --show-toplevel | Out-String).Trim()
} finally {
    Pop-Location
}
if (-not $repoRoot) {
    throw "Could not resolve repo root via 'git rev-parse --show-toplevel'."
}
$artifactWorkRoot = Join-Path $repoRoot '.artifacts\publish'
New-Item -ItemType Directory -Path $artifactWorkRoot -Force | Out-Null

# Production publishes must never proceed with a stale generated operator file.
# Test and local-publish modes do not release or deploy repository access files.
if (-not $SkipDriftCheck -and -not $LocalMode) {
    Write-Step "Validating operators match the whitelist..."
    $syncOpsScript = Join-Path $repoRoot 'scripts/sync-ops.ps1'
    & $syncOpsScript -Check
}

# ─── CI vs local drift detection ────────────────────────────────────────────
# In CI ($env:CI='true'), actions/checkout produces a clean tree from
# origin/main so these checks are vacuous. In local runs, drift between
# the working packwiz/ tree and origin/main would cause the client zip
# (built from disk) to diverge from the SHA pin written into latest.json
# packwizUrl and docker-compose.yml (resolved once via `git rev-parse HEAD`
# before the manifest is built).
if ($env:CI -eq 'true') {
    Write-Step "CI mode detected (`$env:CI='true'`); skipping local drift checks."
} elseif ($SkipDriftCheck) {
    Write-Step "Test-publish mode (-SkipDriftCheck); skipping local drift checks."
} elseif ($LocalMode) {
    Write-Step "Local-publish mode (-LocalOutDir); skipping drift checks (no server-side SHA pin)."
} else {
    Write-Step "Local mode; checking packwiz/ for drift vs origin/main..."

    Push-Location $repoRoot
    try {
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

        # --stat (not --quiet) because $PSNativeCommandUseErrorActionPreference
        # is on and --quiet exiting 1 on diff would throw before we can report
        # the diff cleanly.
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
# Prefer staging instance from build-instance-from-packwiz.ps1. Falls back to
# a hand-curated local Prism instance for hotfix scenarios (loud warning).
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

# If the leaf doesn't match -InstanceName, prefer the leaf (it dictates the
# in-zip folder name). Bail loudly on a non-default conflict — silent rename
# is too magical.
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

# ─── user-prefs manifest resolution ────────────────────────────────────────
# packwiz/.user-prefs.txt is the curated list of pack-shipped files that
# players typically tune (mod graphics, shaders, map style, etc.). We
# transform it into a JSON blob bundled at <InstanceName>/.negativezone/
# preserve-list.json so nz setup/update preserve them transactionally and
# nz backup can widen snapshot scope to match.
#
# Optional: if the manifest is missing, the publish still succeeds and
# the client falls back to its hardcoded $PreserveRelative (player-state
# dirs only — saves, XaeroWaypoints, etc.). This keeps the publish flow
# unblocked while the manifest is being curated.
if (-not $UserPrefsPath) {
    $UserPrefsPath = Join-Path $repoRoot 'packwiz/.user-prefs.txt'
}
if (Test-Path -LiteralPath $UserPrefsPath) {
    $UserPrefsPath = (Resolve-Path -LiteralPath $UserPrefsPath).Path
} else {
    Write-Host "    [warn] user-prefs manifest not found at: $UserPrefsPath" -ForegroundColor Yellow
    Write-Host "    [warn] Published zip will rely on client-side hardcoded preserve list only." -ForegroundColor Yellow
    $UserPrefsPath = $null
}

# ─── Git preflight ─────────────────────────────────────────────────────────
# Fast-fail on the two states that produced PR #121's conflict:
#   1. Dirty working tree → would mix unrelated edits into the auto-PR.
#   2. Existing origin/modpack/v<Version> → would silently stack on stale state.
$publishBranch = "modpack/v$Version"

if ($LocalMode) {
    Write-Step "Local-publish mode; skipping git preflight (no branch/PR will be created)."
} else {
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
            # Capture SHA at preflight to pass an explicit lease via
            # `--force-with-lease=<ref>:<sha>`. The default lease (no `:<sha>`)
            # trusts the local tracking ref, which is unsafe here because a
            # background fetcher (VS Code, GCM) could advance it during the
            # multi-minute zip + upload + push window.
            $expectedRemoteSha = (git rev-parse $remoteRef | Out-String).Trim()
            if (-not $Force) {
                $existingPrUrl = ''
                try {
                    $existingPrUrl = (gh pr list --head $publishBranch --base main --state open --json url --jq '.[0].url' | Out-String).Trim()
                } catch {
                    # gh may fail (auth / rate limit) — let the real error through.
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
}

# Blob preflight: versioned zip lives at an immutable URL (CDN cached),
# so overwriting with different bytes is a player-visible correctness
# hazard. -SkipDriftCheck loosens this for iterative test runs at the
# same -Version (safe: test blobs only consumed by boxes that explicitly
# set NEGATIVEZONE_MANIFEST_URL). Local mode writes to a directory, so there
# is no immutable-URL hazard — always overwrites.
if ($LocalMode) {
    Write-Step "Local-publish mode; skipping Azure blob existence check."
} else {
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
        throw "Immutable blob 'c2e2-v$Version.zip' already exists in '$StorageAccount/$Container'. Pick a new -Version or use -Force only to resume with identical bytes."
    } else {
        Write-Host "    [warn] Blob exists; -Force will verify and reuse it, never overwrite it" -ForegroundColor Yellow
    }
}
}

# ─── Export ────────────────────────────────────────────────────────────────
$blobName = "c2e2-v$Version.zip"
$tempZip  = Join-Path $artifactWorkRoot $blobName

Write-Step "Exporting Prism instance '$InstanceName' -> $tempZip"
if (Test-Path $tempZip) { Remove-Item $tempZip -Force }

# Keep mods/, config/, resourcepacks/, shaderpacks/, sanitized instance.cfg,
# mmc-pack.json, and pre-configured servers.dat. Exclude user-specific state.
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
    # Skip the whole .negativezone/ subtree. Only the generated preservation
    # manifest is added below. This prevents local nz binaries, logs, journals,
    # and snapshots from leaking into a published zip.
    '*/.negativezone/*'
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

# Removes machine-specific Java fields, user state, [UI] section. Pins
# memory + iconKey + version label. Source-instance custom commands are stripped;
# nz setup writes the absolute nz check/backup hooks into the staged instance.
function Get-SanitizedInstanceCfg(
    [string]$path,
    [string]$iconKey,
    [string]$instanceName,
    [string]$version
) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    # Normalize to CRLF (Prism writes CRLF on Windows).
    $lines = $raw -split "\r?\n"

    # Fields tied to admin's local JDK install.
    $stripExact = @(
        'JavaPath', 'JavaSignature', 'JavaArchitecture', 'JavaRealArchitecture',
        'JavaVendor', 'JavaVersion',
        'lastLaunchTime', 'lastTimePlayed', 'totalTimePlayed',
        'LastLaunchTime', 'LastTimePlayed', 'TotalTimePlayed',
        'ExportAuthor', 'ExportName', 'ExportSummary', 'ExportVersion',
        'ExportOptionalFiles', 'PreLaunchCommand', 'PostExitCommand'
    )

    # 8192 MB matches C2E2's recommended ceiling (players on 8 GB systems
    # should lower to 4096 after install). name= carries the version suffix
    # so Prism's instance grid shows it. Custom commands are deliberately off in
    # the distribution zip; nz setup installs nz.exe and enables its hooks before
    # the staged instance is promoted.
    $overrides = [ordered]@{
        'AutomaticJava'         = 'true'
        'OverrideJavaLocation'  = 'false'
        'OverrideMemory'        = 'true'
        'MinMemAlloc'           = '512'
        'MaxMemAlloc'           = '8192'
        'iconKey'               = $iconKey
        'name'                  = "$instanceName v$version"
        'OverrideCommands'      = 'false'
    }

    $out = New-Object System.Collections.Generic.List[string]
    $inUiSection = $false
    $seenKeys = @{}

    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd()

        # Drop [UI] section — window state etc. is user-specific and would
        # clobber the player's layout on every update.
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

    # Append any override keys not already present. [General] is always first
    # in Prism's cfg so a missing key lands there, which is what we want.
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
    # -Force is load-bearing on Linux runners: pwsh treats dot-prefix
    # directories (.minecraft/) as hidden and Get-ChildItem silently
    # skips them without -Force. That's how v0.4.0 shipped as a 30 KB
    # zip containing just instance.cfg + mmc-pack.json — the 8844-file
    # packwiz install under .minecraft/ was never enumerated. Windows
    # pwsh doesn't filter by dot-prefix (only by Hidden attribute), so
    # local admin publishes hid the bug for every version up to v0.3.0.
    $files = Get-ChildItem -Path $instancePath -Recurse -File -Force
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($basePath.Length + 1)
        if (ShouldExclude $relativePath) { continue }
        $entryName = $relativePath -replace '\\', '/'

        if ($file.FullName -eq $instanceCfgPath) {
            # Write the sanitized cfg in place of the on-disk one so we don't
            # mutate the admin's local Prism state.
            $entry = $zip.CreateEntry($entryName, 'Optimal')
            $writer = New-Object System.IO.StreamWriter($entry.Open(), [System.Text.UTF8Encoding]::new($false))
            try { $writer.Write($sanitizedCfg) } finally { $writer.Dispose() }
        } else {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.FullName, $entryName, 'Optimal') | Out-Null
        }
    }

    # Bundle the icon at icons/<IconKey>.<ext> — basename MUST equal the
    # iconKey or Prism won't find it after nz setup copies icons/* to
    # %APPDATA%\PrismLauncher\icons\.
    $iconEntry = "icons/$IconKey$($iconFile.Extension.ToLower())"
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, $iconFile.FullName, $iconEntry, 'Optimal') | Out-Null
    Write-Ok "Bundled icon: $($iconFile.Name) -> $iconEntry"

    # Bundle the curated user-prefs manifest as JSON at
    # <InstanceName>/.negativezone/preserve-list.json so nz setup/update and
    # nz backup know which pack-shipped files
    # the player typically tunes. The source-of-truth is packwiz/.user-prefs.txt
    # (plain-text, # comments, one path per line); we transform to JSON here
    # so the client has a single-format payload that's trivial to parse with
    # ConvertFrom-Json. Schema version is pinned so future format bumps can
    # be detected by the client.
    if ($UserPrefsPath) {
        $preserveLines = Get-Content -LiteralPath $UserPrefsPath -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^\s*#' }
        $preserveJson = ConvertTo-Json @{
            version  = 1
            preserve = @($preserveLines)
        } -Depth 4 -Compress
        $preserveTempPath = Join-Path $artifactWorkRoot ("preserve-{0}.json" -f [guid]::NewGuid().ToString('N'))
        try {
            # -NoNewline avoids a trailing newline that some strict JSON
            # parsers reject (PowerShell's ConvertFrom-Json is tolerant
            # but other consumers like jq aren't).
            Set-Content -LiteralPath $preserveTempPath -Value $preserveJson -Encoding UTF8 -NoNewline
            $preserveEntry = "$InstanceName/.negativezone/preserve-list.json"
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $preserveTempPath, $preserveEntry, 'Optimal') | Out-Null
            Write-Ok ("Bundled preserve-list.json ({0} entries) -> $preserveEntry" -f $preserveLines.Count)
        } finally {
            Remove-Item -LiteralPath $preserveTempPath -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    $zip.Dispose()
}

$sizeMb = [math]::Round((Get-Item $tempZip).Length / 1MB, 1)
Write-Ok "Zip size: ${sizeMb} MB"

# ─── Post-zip structural sanity check ──────────────────────────────────────
# Belt-and-suspenders on top of the Get-ChildItem -Force fix above: open
# the freshly-built zip and confirm it actually contains mod JARs under
# <InstanceName>/.minecraft/mods/. v0.4.0 logged "Zip size: 0 MB" (30 KB
# in reality) and uploaded anyway, then the empty zip propagated to every
# player who installed it. The auto-merged PR even rewrote modpack.yml
# to point at the broken blob. Refuse to ship anything that can't carry
# the modpack — the deliberately loud throw here is far less painful than
# the FML handshake errors players hit on first connect.
$verifyZip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
try {
    $modEntryPrefix = "$InstanceName/.minecraft/mods/"
    $modEntries = @($verifyZip.Entries | Where-Object {
        $_.FullName.StartsWith($modEntryPrefix) -and $_.FullName.EndsWith('.jar')
    })
    $legacyEntries = @($verifyZip.Entries | Where-Object {
        $_.FullName -in @(
            "$InstanceName/.negativezone/update.ps1",
            "$InstanceName/.negativezone/backup.ps1",
            "$InstanceName/.negativezone/prelaunch-check.ps1"
        )
    })
    $cfgEntry = $verifyZip.GetEntry("$InstanceName/instance.cfg")
    if (-not $cfgEntry) {
        throw "Built zip is missing $InstanceName/instance.cfg."
    }
    $cfgReader = [IO.StreamReader]::new($cfgEntry.Open())
    try {
        $packagedCfg = $cfgReader.ReadToEnd()
    } finally {
        $cfgReader.Dispose()
    }
} finally { $verifyZip.Dispose() }
if ($modEntries.Count -lt 1) {
    throw ("Built zip '$tempZip' contains 0 entries matching '$modEntryPrefix*.jar'. " +
           "Aborting — refusing to upload an empty pack. " +
           "Did build-instance-from-packwiz.ps1 actually populate .minecraft/mods/, " +
           "and is Get-ChildItem -Force still in the export loop above?")
}
if ($legacyEntries.Count -gt 0) {
    throw "Built zip contains retired PowerShell client hooks: $($legacyEntries.FullName -join ', ')"
}
if ($packagedCfg -notmatch '(?m)^OverrideCommands=false\r?$' -or
    $packagedCfg -match '(?m)^(PreLaunchCommand|PostExitCommand)=') {
    throw 'Built zip instance.cfg does not defer client hook installation to nz setup.'
}
Write-Ok ("Verified: zip carries {0} mod JARs under {1}" -f $modEntries.Count, $modEntryPrefix)
Write-Ok 'Verified: zip contains no legacy PowerShell client hooks'

# ─── SHA-256 ───────────────────────────────────────────────────────────────
Write-Step "Computing SHA-256"
$sha = (Get-FileHash $tempZip -Algorithm SHA256).Hash.ToLower()
Write-Ok "sha256 = $sha"

# ─── Upload (or local copy) ─────────────────────────────────────────────────
if ($LocalMode) {
    $localZipPath = Join-Path $LocalOutDir $blobName
    Write-Step "Copying zip -> $localZipPath"
    Copy-Item -LiteralPath $tempZip -Destination $localZipPath -Force
    Write-Ok "Local zip written"
} elseif ($blobAlreadyExists -and -not $SkipDriftCheck) {
    $existingZip = Join-Path $artifactWorkRoot "existing-$blobName"
    Remove-Item -LiteralPath $existingZip -Force -ErrorAction SilentlyContinue
    Write-Step "Verifying existing immutable blob $blobName"
    az storage blob download `
        --account-name $StorageAccount `
        --container-name $Container `
        --name $blobName `
        --file $existingZip `
        --auth-mode login `
        --overwrite true `
        --output none
    $existingSHA = (Get-FileHash -LiteralPath $existingZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Remove-Item -LiteralPath $existingZip -Force -ErrorAction SilentlyContinue
    if ($existingSHA -ne $sha) {
        throw "Immutable blob $blobName already exists with SHA-256 $existingSHA, but this build produced $sha. Use a new version."
    }
    Write-Ok "Existing immutable zip matches; reusing it"
} else {
    # Production versioned assets are immutable. Test-mode assets are isolated
    # behind latest-test.json and may be overwritten for iterative validation.
    $overwriteFlag = if ($SkipDriftCheck) { 'true' } else { 'false' }
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
}

# ─── Build immutable version manifest ───────────────────────────────────────
Write-Step "Building immutable version manifest"
Push-Location $repoRoot
try {
    $packwizSha = (git rev-parse HEAD | Out-String).Trim()
} finally {
    Pop-Location
}
if ($packwizSha -notmatch '^[0-9a-f]{40}$') {
    throw "Unexpected SHA from 'git rev-parse HEAD': '$packwizSha'"
}
$packTomlContent = Get-Content -LiteralPath (Join-Path $repoRoot 'packwiz\pack.toml') -Raw
$minecraftMatch = [regex]::Match($packTomlContent, '(?m)^minecraft\s*=\s*"([^"]+)"')
if (-not $minecraftMatch.Success) {
    throw 'Could not read the Minecraft compatibility version from packwiz/pack.toml.'
}
$minecraftVersion = $minecraftMatch.Groups[1].Value
$packwizUrl = "https://raw.githubusercontent.com/camcast3/MinecraftInfra/$packwizSha/packwiz/pack.toml"
$manifestUrl = if ($LocalMode) { "$LocalBaseUrl/$blobName" } else { "https://$StorageAccount.blob.core.windows.net/$Container/$blobName" }
$preserveListName = "c2e2-v$Version-preserve-list.json"
$preserveListUrl = if ($LocalMode) {
    "$LocalBaseUrl/$preserveListName"
} else {
    "https://$StorageAccount.blob.core.windows.net/$Container/$preserveListName"
}
$preserveLines = if ($UserPrefsPath) {
    @(Get-Content -LiteralPath $UserPrefsPath -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^\s*#' })
} else {
    @()
}
$preserveManifest = [ordered]@{
    version = 1
    preserve = $preserveLines
}
$preserveManifestPath = if ($LocalMode) {
    Join-Path $LocalOutDir $preserveListName
} else {
    Join-Path $artifactWorkRoot $preserveListName
}
[IO.File]::WriteAllText(
    $preserveManifestPath,
    ($preserveManifest | ConvertTo-Json -Depth 4 -Compress),
    [Text.UTF8Encoding]::new($false)
)
$manifest = [ordered]@{
    schemaVersion = 1
    version    = $Version
    blob       = $blobName
    url        = $manifestUrl
    packwizUrl = $packwizUrl
    preserveListUrl = $preserveListUrl
    sha256     = $sha
    sizeBytes  = (Get-Item $tempZip).Length
    instance   = $InstanceName
    publishedAt = (Get-Date).ToUniversalTime().ToString('o')
    sourceCommit = $packwizSha
    compatibility = [ordered]@{
        minecraft = $minecraftVersion
        javaMajor = 17
        manifestSchema = 1
        preserveListSchema = 1
        transactionSchema = 1
    }
}
if ($AllowDowngrade) {
    # Opt-in field — only emitted when the admin explicitly approves rollback.
    # nz update/setup refuse downgrades unless this is true.
    $manifest['allowDowngrade'] = $true
    Write-Host "    [warn] AllowDowngrade=true: players on newer versions WILL roll back to v$Version" -ForegroundColor Yellow
}

# Local mode writes the immutable manifest straight into the output dir.
# Production stages it under .artifacts before uploading it beside the zip.
$versionManifestName = "c2e2-v$Version.json"
$manifestPath = if ($LocalMode) {
    Join-Path $LocalOutDir $versionManifestName
} else {
    Join-Path $artifactWorkRoot $versionManifestName
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8

if ($LocalMode) {
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $LocalOutDir 'latest.json') -Force
} elseif (-not $SkipDriftCheck) {
    $preserveExistsJson = (& az storage blob exists `
        --account-name $StorageAccount `
        --container-name $Container `
        --name $preserveListName `
        --auth-mode login `
        --output json | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query immutable preserve manifest (az exit code $LASTEXITCODE)."
    }
    if (-not ($preserveExistsJson | ConvertFrom-Json).exists) {
        & az storage blob upload `
            --account-name $StorageAccount `
            --container-name $Container `
            --name $preserveListName `
            --file $preserveManifestPath `
            --auth-mode login `
            --overwrite false `
            --content-type "application/json" `
            --content-cache-control "public, max-age=31536000, immutable" `
            --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to upload immutable preserve manifest (az exit code $LASTEXITCODE)."
        }
    } elseif (-not $Force) {
        throw "Immutable preserve manifest $preserveListName already exists. Pick a new version or use -Force only to resume an identical publish."
    } else {
        $existingPreservePath = Join-Path $artifactWorkRoot "existing-$preserveListName"
        & az storage blob download `
            --account-name $StorageAccount `
            --container-name $Container `
            --name $preserveListName `
            --file $existingPreservePath `
            --auth-mode login `
            --overwrite true `
            --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to download immutable preserve manifest (az exit code $LASTEXITCODE)."
        }
        try {
            $existingPreserveHash = (Get-FileHash -LiteralPath $existingPreservePath -Algorithm SHA256).Hash
            $newPreserveHash = (Get-FileHash -LiteralPath $preserveManifestPath -Algorithm SHA256).Hash
            if ($existingPreserveHash -ne $newPreserveHash) {
                throw "Existing immutable preserve manifest $preserveListName differs from this build."
            }
        } finally {
            Remove-Item -LiteralPath $existingPreservePath -Force -ErrorAction SilentlyContinue
        }
    }

    $manifestExistsJson = (az storage blob exists `
        --account-name $StorageAccount `
        --container-name $Container `
        --name $versionManifestName `
        --auth-mode login `
        --output json | Out-String).Trim()
    if (($manifestExistsJson | ConvertFrom-Json).exists) {
        if (-not $Force) {
            throw "Immutable manifest $versionManifestName already exists. Pick a new version or use -Force only to resume an identical publish."
        }
        $existingManifestPath = Join-Path $artifactWorkRoot "existing-$versionManifestName"
        az storage blob download `
            --account-name $StorageAccount `
            --container-name $Container `
            --name $versionManifestName `
            --file $existingManifestPath `
            --auth-mode login `
            --overwrite true `
            --output none
        $existingManifest = Get-Content -LiteralPath $existingManifestPath -Raw | ConvertFrom-Json
        Remove-Item -LiteralPath $existingManifestPath -Force -ErrorAction SilentlyContinue
        if ($existingManifest.version -ne $Version -or
            $existingManifest.sha256 -ne $sha -or
            $existingManifest.packwizUrl -ne $packwizUrl -or
            $existingManifest.preserveListUrl -ne $preserveListUrl -or
            $existingManifest.compatibility.transactionSchema -ne 1) {
            throw "Existing immutable manifest $versionManifestName is not compatible with this build. Use a new version."
        }
        $manifest = $existingManifest
        Write-Ok "Existing immutable manifest matches; reusing it"
    } else {
        Write-Step "Uploading immutable manifest $versionManifestName"
        az storage blob upload `
            --account-name $StorageAccount `
            --container-name $Container `
            --name $versionManifestName `
            --file $manifestPath `
            --auth-mode login `
            --overwrite false `
            --content-type "application/json" `
            --content-cache-control "public, max-age=31536000, immutable" `
            --output none
    }
}

# ─── Update modpack.yml + .env + open PR ───────────────────────────────────
# Skipped in test-publish mode — latest-test.json still gets packwizUrl from
# the current HEAD, but no server-side compose rewrite or PR is created.
# Skipped entirely in local-publish mode (no server-side mutation at all).
if ($SkipDriftCheck) {
    Write-Step "Test-publish mode; skipping modpack.yml + docker-compose.yml rewrite + PR creation."
} elseif ($LocalMode) {
    Write-Step "Local-publish mode; skipping modpack.yml + docker-compose.yml rewrite + PR creation."
} else {
    Write-Step "Creating branch '$publishBranch' from origin/main"
    Push-Location $repoRoot
    try {
        # ALWAYS branch from fresh origin/main, NEVER from local HEAD. The
        # old `if (currentBranch -eq 'main') { git checkout -b ... }` was
        # PR #121's root cause: re-running from a leftover publish branch
        # silently stacked the new commit on stale history.
        git checkout -B $publishBranch "origin/main"

        # Reuse the manifest SHA so client packwizUrl and server PACKWIZ_URL
        # stay pinned to one validated packwiz/ snapshot.

        # Write modpack.yml AFTER the branch reset so the new content survives.
        $modpackYml = Join-Path $repoRoot 'modpack.yml'
        $publishedAt = ([DateTimeOffset]::Parse([string]$manifest.publishedAt)).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $yamlContent = @"
# Central modpack version record — updated by publish-prism-pack.ps1
# This provides a committed, auditable record of the currently published pack.
version: "$Version"
blob: $blobName
sha256: $sha
url: https://$StorageAccount.blob.core.windows.net/$Container/$blobName
instance: $InstanceName
publishedAt: "$publishedAt"
manifest: https://$StorageAccount.blob.core.windows.net/$Container/$versionManifestName
"@
        Set-Content -Path $modpackYml -Value $yamlContent -Encoding UTF8

        # Atomic SHA + version bump: rewriting PACKWIZ_URL + MOTD in the same
        # commit as modpack.yml means Portainer GitOps redeploys the server
        # with the new MOTD and SHA-pinned mod set; nz's launch check then
        # directs players to the gated update. Server + client move together.
        #
        # We rewrite compose YAML (not .env) because Portainer's GitOps mode
        # polls compose changes and ignores .env files in git.
        $composeFile = Join-Path $repoRoot 'docker/proxmox/docker-compose.yml'
        if (-not (Test-Path -LiteralPath $composeFile)) {
            throw "Expected $composeFile to exist. Cannot bump PACK_VERSION / PACKWIZ_COMMIT_SHA."
        }
        $composeContent = Get-Content -Raw -LiteralPath $composeFile -Encoding UTF8

        # Anchor on the github.com path so we don't rewrite any unrelated URL
        # that happens to look like a sha. Fail loudly on != 1 match — a
        # silently-no-op publish would let server and client drift.
        $urlRegex = '(?m)^(\s*PACKWIZ_URL:\s*"https://raw\.githubusercontent\.com/camcast3/MinecraftInfra/)([^/"]+)(/packwiz/pack\.toml")\s*$'
        $urlMatches = [regex]::Matches($composeContent, $urlRegex)
        if ($urlMatches.Count -ne 1) {
            throw ("Expected exactly 1 PACKWIZ_URL line in $composeFile (matched {0}). " +
                   "Has the line been manually edited?") -f $urlMatches.Count
        }
        $composeContent = [regex]::Replace($composeContent, $urlRegex, "`${1}$packwizSha`${3}")

        # Pin MOTD version. Same exactly-1-match guard.
        $motdRegex = '(?m)^(\s*MOTD:\s*"Craft to Exile 2 v)([^"]+)(")\s*$'
        $motdMatches = [regex]::Matches($composeContent, $motdRegex)
        if ($motdMatches.Count -ne 1) {
            throw ("Expected exactly 1 MOTD line in $composeFile (matched {0}). " +
                   "Has the line been manually edited?") -f $motdMatches.Count
        }
        $composeContent = [regex]::Replace($composeContent, $motdRegex, "`${1}$Version`${3}")

        # Write back UTF-8 no-BOM, original line endings preserved (Get-Content
        # -Raw + WriteAllText keeps the existing `r`n vs `n).
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($composeFile, $composeContent, $utf8NoBom)
        Write-Ok "Rewrote docker/proxmox/docker-compose.yml: PACKWIZ_URL pinned to $packwizSha, MOTD pinned to v$Version"

        # Velocity fallback MOTD (shown when the C2E2 backend is unreachable —
        # ping-passthrough = "ALL" otherwise surfaces the backend's MOTD).
        # Kept in lockstep with the backend MOTD so players always see the
        # currently-published version, even during a backend outage. Same
        # exactly-1-match guard.
        $velocityTmpl = Join-Path $repoRoot 'docker/azure/velocity/velocity.toml.tmpl'
        if (-not (Test-Path -LiteralPath $velocityTmpl)) {
            throw "Expected $velocityTmpl to exist. Cannot bump Velocity fallback MOTD."
        }
        $velocityContent = Get-Content -Raw -LiteralPath $velocityTmpl -Encoding UTF8
        $velocityMotdRegex = '(?m)^(motd\s*=\s*"Craft to Exile 2 v)([^"]+)(")\s*$'
        $velocityMotdMatches = [regex]::Matches($velocityContent, $velocityMotdRegex)
        if ($velocityMotdMatches.Count -ne 1) {
            throw ("Expected exactly 1 fallback motd line in $velocityTmpl (matched {0}). " +
                   "Has the line been manually edited?") -f $velocityMotdMatches.Count
        }
        $velocityContent = [regex]::Replace($velocityContent, $velocityMotdRegex, "`${1}$Version`${3}")
        [System.IO.File]::WriteAllText($velocityTmpl, $velocityContent, $utf8NoBom)
        Write-Ok "Rewrote docker/azure/velocity/velocity.toml.tmpl: fallback motd pinned to v$Version"

        git add modpack.yml `
            'docker/proxmox/docker-compose.yml' `
            'docker/azure/velocity/velocity.toml.tmpl'
        git commit -m "chore(modpack): publish v$Version`n`nsha256: $sha`npackwiz_sha: $packwizSha"

        Write-Step "Pushing $publishBranch to origin"
        if ($Force -and $expectedRemoteSha) {
            # Explicit lease tied to the SHA we observed at preflight. Refuses
            # if anything (concurrent publisher OR background auto-fetch)
            # moved the branch since then.
            git push "--force-with-lease=refs/heads/${publishBranch}:${expectedRemoteSha}" -u origin HEAD
        } else {
            # Plain push fails loudly if a concurrent publisher created the
            # branch in the meantime.
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
- ``modpack.yml`` — the published-version audit record consumed by ``nz setup``.
- ``docker/proxmox/docker-compose.yml`` — ``PACKWIZ_URL`` pinned to the new
  packwiz SHA, ``MOTD`` pinned to the new version. Portainer GitOps redeploys
  C2E2 within ~5 min of merge, pulling the same packwiz snapshot that's bundled
  in the client zip above. Server + client move in lockstep.
- ``docker/azure/velocity/velocity.toml.tmpl`` — Velocity fallback ``motd``
  pinned to the new version. Surfaces the current version to players when the
  C2E2 backend is briefly unreachable (deploy-azure.yml redeploys the proxy on
  merge; refresh-env.sh restarts Velocity if velocity.toml content changed).

The immutable client zip and manifest are staged but neither ``latest.json``
nor the launch-time version pointers move in this workflow. After this PR
merges, ``promote-prism-pack.yml`` waits for the public server to report
v$Version, verifies the immutable manifest, and only then promotes stable.
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

        # Enable auto-merge so the PR squash-merges as soon as required reviews
        # / checks pass. Shrinks the window where a second publish could race
        # and collide.
        #
        # FAIL LOUD: a silent warning here strands the PR with no merge intent.
        # Stable pointers are now promoted by promote-prism-pack.yml only after
        # merge and server health, so this workflow can stage candidates safely.
        # Recovery: enable
        # `allow_auto_merge` on the repo (Settings → General → Pull Requests,
        # or `gh api -X PATCH /repos/<owner>/<repo> -F allow_auto_merge=true`)
        # then re-run with -Force.
        try {
            gh pr merge $prUrl --auto --squash --delete-branch | Out-Null
            Write-Ok "Auto-merge enabled (squash + delete branch)"
        } catch {
            throw @"
Failed to enable auto-merge on $prUrl :
$($_.Exception.Message)

Most likely cause: ``allow_auto_merge`` is disabled on this repo. Fix via
GitHub UI (Settings → General → Pull Requests → "Allow auto-merge") or:
  gh api -X PATCH /repos/<owner>/<repo> -F allow_auto_merge=true

Branch + immutable candidate assets are already staged but no stable pointer
has moved. Once the repo setting is fixed, re-run this script with -Force to
verify/reuse the assets, reuse the existing PR, and enable auto-merge.
"@
        }
    } finally {
        Pop-Location
    }
}

# ─── Publish test pointer / leave production candidate staged ───────────────
# Production stable pointers are promoted by promote-prism-pack.yml after the
# PR merges and the public server reports the expected version. Test mode keeps
# its isolated mutable pointer; local mode already wrote latest.json locally.
if ($LocalMode) {
    Write-Host ""
    Write-Host "Local publish complete (nothing uploaded; no git/PR)." -ForegroundColor Green
    Write-Host "  Output dir : $LocalOutDir"
    Write-Host "  Manifest   : $(Join-Path $LocalOutDir $versionManifestName)"
    Write-Host "  Local alias: $(Join-Path $LocalOutDir 'latest.json')  (url -> $manifestUrl)"
    Write-Host "  Zip        : $(Join-Path $LocalOutDir $blobName)"
    Write-Host ""
    Write-Host "Serve $LocalOutDir over HTTP at $LocalBaseUrl, then point setup at it:" -ForegroundColor Cyan
    Write-Host "  `$env:NEGATIVEZONE_MANIFEST_URL = '$LocalBaseUrl/latest.json'" -ForegroundColor Cyan
    Write-Host "  & nz.exe setup" -ForegroundColor Cyan
    Write-Host ""
    # Keep the LocalOutDir zip + manifest (they ARE the deliverable); only the
    # temp build artifact is removed.
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    return
}

$manifestBlobName = if ($SkipDriftCheck) { 'latest-test.json' } else { $versionManifestName }
if ($SkipDriftCheck) {
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
}

# ─── Cleanup ───────────────────────────────────────────────────────────────
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($SkipDriftCheck) {
    Write-Host "Test-publish complete (production latest.json untouched)." -ForegroundColor Green
    Write-Host "  Test manifest: https://$StorageAccount.blob.core.windows.net/$Container/$manifestBlobName"
    Write-Host "  Test zip:      https://$StorageAccount.blob.core.windows.net/$Container/$blobName"
    Write-Host ""
    Write-Host "To install this test publish, set the manifest URL override before running nz setup:" -ForegroundColor Cyan
    Write-Host "  `$env:NEGATIVEZONE_MANIFEST_URL = 'https://$StorageAccount.blob.core.windows.net/$Container/$manifestBlobName'" -ForegroundColor Cyan
    Write-Host "  & `$env:LOCALAPPDATA\NegativeZone\nz.exe setup" -ForegroundColor Cyan
} else {
    Write-Host "Candidate staged successfully; stable pointers are unchanged." -ForegroundColor Green
    Write-Host "  Immutable manifest: https://$StorageAccount.blob.core.windows.net/$Container/$versionManifestName"
    Write-Host "  Immutable zip:      https://$StorageAccount.blob.core.windows.net/$Container/$blobName"
    Write-Host "  Promotion:          automatic after PR merge + public server health"
}
Write-Host ""
