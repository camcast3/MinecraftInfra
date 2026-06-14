#requires -Version 7.0
<#
.SYNOPSIS
    Export a Prism Launcher instance and publish it to Azure Blob storage so
    setup.ps1 can pull it in ~2 min instead of waiting through CurseForge.
    Bundles update.ps1 + wires the PreLaunchCommand so installed instances
    auto-update against the latest published manifest.

    Sanitizes instance.cfg (strips local Java fields, forces AutomaticJava,
    pins memory + iconKey + version label, wires PreLaunchCommand). Bundles
    icon + update.ps1 into the zip. Uploads versioned blob with immutable
    cache headers. Atomically commits modpack.yml + rewrites
    docker/proxmox/docker-compose.yml (PACKWIZ_URL pinned to current HEAD
    SHA, MOTD pinned to new version) + docker/azure/velocity/velocity.toml.tmpl
    (Velocity fallback MOTD pinned to new version) + docs/assets/latest-version.txt
    (launch-time version pointer polled by prelaunch-check.ps1) on a fresh
    modpack/v<Version> branch, opens a PR with auto-merge. Portainer GitOps
    redeploys C2E2 within ~5 min — server + client + fallback-proxy MOTD +
    launch-time pointer all move in lockstep. Compose YAML is rewritten
    directly (not .env) because Portainer ignores .env files in git.
    latest.json is uploaded AFTER PR succeeds so the audit trail is always
    present before any player can download.

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

.PARAMETER UpdateScriptPath
    update.ps1 to bundle into the zip. Default: docs/assets/update.ps1.

.PARAMETER BackupScriptPath
    Path to the player-side `backup.ps1` to bundle into the zip at
    <InstanceName>/.negativezone/backup.ps1. Defaults to
    docs/assets/backup.ps1 from the repo root. Wired into instance.cfg's
    PostExitCommand by the sanitizer so periodic snapshots of player state
    (Xaero map cache, shaderpacks, options, etc.) happen after every game
    session — see backup.ps1 for the cadence (default 3 days) and scope.

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
    Also the recovery mode for resuming a publish that failed at the
    auto-merge step (PR #147 root cause): re-running with -Force after
    enabling `allow_auto_merge` on the repo will reuse the existing PR,
    enable auto-merge, and finally upload latest.json.

.PARAMETER SkipDriftCheck
    Test-publish escape hatch — bypasses drift check AND server-side
    coupling (compose-rewrite + PR + auto-merge). -Version MUST start
    with "test-". Manifest goes to latest-test.json, not latest.json.
    Players using setup.ps1 stay on production unless they set

.PARAMETER AllowDowngrade
    Set "allowDowngrade": true in the published manifest so the player-side
    update.ps1 / setup.ps1 will accept rolling back from a newer installed
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
    [string]$UpdateScriptPath,
    [string]$BackupScriptPath,
    [string]$UserPrefsPath,
    [string]$IconPath = (Join-Path $PSScriptRoot 'cte2-icon.png'),
    [string]$IconKey = 'cte2',
    [switch]$Force,
    [switch]$SkipDriftCheck,
    [switch]$AllowDowngrade
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }

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

# ─── CI vs local drift detection ────────────────────────────────────────────
# In CI ($env:CI='true'), actions/checkout produces a clean tree from
# origin/main so these checks are vacuous. In local runs, drift between
# the working packwiz/ tree and origin/main would cause the client zip
# (built from disk) to diverge from the SHA pin written into
# docker-compose.yml (resolved via `git rev-parse HEAD` after a fresh
# `git checkout -B publishBranch origin/main`).
if ($env:CI -eq 'true') {
    Write-Step "CI mode detected (`$env:CI='true'`); skipping local drift checks."
} elseif ($SkipDriftCheck) {
    Write-Step "Test-publish mode (-SkipDriftCheck); skipping local drift checks."
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

# ─── update.ps1 resolution ──────────────────────────────────────────────────
if (-not $UpdateScriptPath) {
    $UpdateScriptPath = Join-Path $repoRoot 'docs/assets/update.ps1'
}
if (-not (Test-Path -LiteralPath $UpdateScriptPath)) {
    throw "update.ps1 not found at: $UpdateScriptPath`nPass -UpdateScriptPath to override."
}
$UpdateScriptPath = (Resolve-Path -LiteralPath $UpdateScriptPath).Path

# ─── backup.ps1 resolution ──────────────────────────────────────────────────
if (-not $BackupScriptPath) {
    $BackupScriptPath = Join-Path $repoRoot 'docs/assets/backup.ps1'
}
if (-not (Test-Path -LiteralPath $BackupScriptPath)) {
    throw "backup.ps1 not found at: $BackupScriptPath`nPass -BackupScriptPath to override."
}
$BackupScriptPath = (Resolve-Path -LiteralPath $BackupScriptPath).Path

# ─── user-prefs manifest resolution ────────────────────────────────────────
# packwiz/.user-prefs.txt is the curated list of pack-shipped files that
# players typically tune (mod graphics, shaders, map style, etc.). We
# transform it into a JSON blob bundled at <InstanceName>/.negativezone/
# preserve-list.json so update.ps1 can restore them across the atomic
# .minecraft swap and backup.ps1 can widen snapshot scope to match.
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

# Blob preflight: versioned zip lives at an immutable URL (CDN cached),
# so overwriting with different bytes is a player-visible correctness
# hazard. -SkipDriftCheck loosens this for iterative test runs at the
# same -Version (safe: test blobs only consumed by boxes that explicitly
# set NEGATIVEZONE_MANIFEST_URL).
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
# [System.IO.Path]::GetTempPath() instead of $env:TEMP — the latter is
# unset on Linux/macOS PowerShell, so the GitHub Actions ubuntu-latest
# runner hit "Cannot bind argument to parameter 'Path' because it is null"
# when Join-Path got a null first argument.
$blobName = "c2e2-v$Version.zip"
$tempZip  = Join-Path ([System.IO.Path]::GetTempPath()) $blobName

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
    # Skip the whole .negativezone/ subtree. The canonical update.ps1 +
    # backup.ps1 are added via CreateEntryFromFile below; this exclude
    # prevents (a) snapshot dirs at .negativezone/backups/<ts>/ from leaking
    # into a published zip if -InstancePath points at an admin's local
    # Prism instance, and (b) duplicate zip entries that would otherwise
    # collide with the explicit bundle of update.ps1 / backup.ps1.
    '*/.negativezone/*'
)

# Compress-Archive doesn't support exclusions, so we use .NET ZipFile directly.
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Re-encodes a player-side .ps1 file as UTF-8 *with* BOM and writes it into
# the zip. Required because PowerShell 5.1 (the Windows default; what Prism
# launches via "powershell.exe") reads unsigned .ps1 files as Windows-1252
# unless a BOM is present. Our scripts contain U+2014 em-dash ("—") in both
# comments and string literals; its UTF-8 encoding is the byte sequence
# E2 80 94, and 0x94 is CP1252's RIGHT DOUBLE QUOTATION MARK ("). Without a
# BOM, PS 5.1 silently closes the surrounding string literal at the em-dash
# and the parser cascades into "Unexpected token ... refusing" / "Missing
# closing ')'" errors that crash the PreLaunchCommand at first launch.
# Source files on disk may or may not have a BOM — File.ReadAllText auto-
# detects and strips it, so this is safe to call on either.
function Add-Ps1ZipEntry(
    [System.IO.Compression.ZipArchive] $zip,
    [string] $sourcePath,
    [string] $entryName
) {
    $text = [System.IO.File]::ReadAllText($sourcePath)
    $entry = $zip.CreateEntry($entryName, 'Optimal')
    $writer = New-Object System.IO.StreamWriter($entry.Open(), [System.Text.UTF8Encoding]::new($true))
    try { $writer.Write($text) } finally { $writer.Dispose() }
}

function ShouldExclude([string]$relativePath) {
    $normalized = $relativePath -replace '\\', '/'
    foreach ($pattern in $excludePatterns) {
        if ($normalized -like $pattern) { return $true }
    }
    return $false
}

# Escapes a string for safe storage in a Qt INI value (the format Prism uses
# for instance.cfg). Prism re-writes the cfg via QSettings on every launch
# (lastLaunchTime, lastTimePlayed). On read, Qt processes `\<letter>` escapes
# and concatenates adjacent `"..."` segments with whitespace stripped — so
# an unescaped raw `"powershell.exe" -NoProfile ... $INST_DIR\.negativezone\update.ps1`
# value becomes `powershell.exe-NoProfile ... $INST_DIRnegativezonepdate.ps1`
# the very first time the player clicks Launch (the closing quote + space
# get eaten; `\.` collapses to `.`; `\u` is interpreted as the start of a
# Unicode escape and silently eats `update`'s `u`). The hook then fails with
# "process failed to start".
#
# Format-QtIniValue emits Qt's canonical escaped form (backslashes -> `\\`,
# double-quotes -> `\"`, whole value wrapped in `"..."`). The round-trip is
# idempotent: Qt's reader undoes the escapes and the writer re-emits the
# same bytes, so subsequent launches don't progressively mangle the value.
# Mirrored verbatim in docs/assets/setup.ps1 — keep in sync.
function Format-QtIniValue {
    param([Parameter(Mandatory)][string] $Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

# Removes machine-specific Java fields, user state, [UI] section. Pins
# memory + iconKey + version label. Wires PreLaunchCommand for auto-update.
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
        'ExportOptionalFiles'
    )

    # Two layers of defense for the Pre/Post launch hooks:
    #
    # 1. Encoding-tolerant invocation: PS 5.1's `-File` reads .ps1 as the
    #    system ANSI codepage (CP1252 on US Windows) unless the file has a
    #    UTF-8 BOM, which mangles em-dashes (U+2014 -> bytes E2 80 94; 0x94
    #    reads as a closing smart-quote and silently terminates string
    #    literals). We publish .ps1 entries WITH BOM, but defense-in-depth:
    #    the `-Command` form uses .NET's UTF-8 decoder explicitly via
    #    File::ReadAllText, so the script parses correctly regardless of
    #    BOM presence or any future editor/tool that strips it.
    #
    # 2. try/catch wrapper: a stale or corrupted update.ps1/backup.ps1
    #    (missing file, parse error, runtime throw) surfaces a clear
    #    "re-run setup.ps1" message in Prism's launch console instead of a
    #    PowerShell stack trace. Without this, the original em-dash parse
    #    crash showed players tokenizer errors with no actionable guidance.
    #
    # Quoting layers (outermost -> innermost):
    #   * Qt INI value wrap: the entire command is the value after `=`.
    #     Backslashes inside "..." are kept literal (no \u/\n escapes).
    #   * QProcess::splitCommand: splits on whitespace; "..." segments stay
    #     intact (handles paths with spaces like "Craft to Exile 2").
    #   * PowerShell `-Command` parser: the value is parsed as a script.
    #     Single quotes inside wrap the path/messages so backslashes,
    #     spaces, and special chars are literal.
    # Here-strings used because the runtime payload contains many literal
    # single quotes — '' escaping inside a single-quoted PS literal would
    # make this near-unreadable. `$INST_DIR` survives unexpanded — Prism
    # substitutes it at launch time.
    $updateInvoke = @'
try { & ([scriptblock]::Create([System.IO.File]::ReadAllText('$INST_DIR\.negativezone\update.ps1', [System.Text.Encoding]::UTF8))) } catch { Write-Host ''; Write-Host '[negativezone] PreLaunch hook failed: your client is out of date or corrupted.'; Write-Host '[negativezone] Re-run the setup one-liner in PowerShell to repair:'; Write-Host '[negativezone]   irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/setup.ps1 | iex'; Write-Host ''; Write-Host ('[negativezone] (underlying error: ' + $_.Exception.Message + ')'); exit 1 }
'@
    # PostExit fails OPEN (exit 0) — player already finished playing; a
    # blocking popup here adds friction with no recovery benefit. The next
    # PreLaunch will surface the same condition loudly and block until fixed.
    $backupInvoke = @'
try { & ([scriptblock]::Create([System.IO.File]::ReadAllText('$INST_DIR\.negativezone\backup.ps1', [System.Text.Encoding]::UTF8))) } catch { Write-Host ''; Write-Host '[negativezone] PostExit backup hook failed: your client is out of date or corrupted.'; Write-Host '[negativezone] Re-run the setup one-liner in PowerShell to repair:'; Write-Host '[negativezone]   irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/setup.ps1 | iex'; Write-Host ('[negativezone] (underlying error: ' + $_.Exception.Message + ')'); exit 0 }
'@
    $preLaunchCommand = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "' + $updateInvoke + '"'
    $postExitCommand  = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "' + $backupInvoke + '"'

    # Apply Qt INI value escape — Prism re-writes instance.cfg via QSettings
    # on every launch (lastLaunchTime update), and without escaping the raw
    # `"..."` segments + `\.` / `\u` sequences get mangled (closing quotes
    # eaten, backslashes dropped, `\u` interpreted as Unicode escape). See
    # the matching Format-QtIniValue in docs/assets/setup.ps1 for the full
    # story. Inlined here so this script stays standalone (used in CI).
    $preLaunchCommand = Format-QtIniValue -Value $preLaunchCommand
    $postExitCommand  = Format-QtIniValue -Value $postExitCommand

    # 8192 MB matches C2E2's recommended ceiling (players on 8 GB systems
    # should lower to 4096 after install). name= carries the version suffix
    # so Prism's instance grid shows it (update.ps1 patches on swap).
    # OverrideCommands + PreLaunchCommand wire the auto-update hook
    # (fail-open on network, fail-closed on SHA mismatch). PostExitCommand
    # wires the periodic-backup hook (always fail-open; cadence-skips in ~100ms
    # when no snapshot is due).
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
        'PostExitCommand'       = $postExitCommand
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
    # iconKey or Prism won't find it after setup.ps1 copies icons/* to
    # %APPDATA%\PrismLauncher\icons\.
    $iconEntry = "icons/$IconKey$($iconFile.Extension.ToLower())"
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, $iconFile.FullName, $iconEntry, 'Optimal') | Out-Null
    Write-Ok "Bundled icon: $($iconFile.Name) -> $iconEntry"

    # Bundle update.ps1 so the PreLaunchCommand has something to run on
    # first launch. Add-Ps1ZipEntry (not CreateEntryFromFile) re-encodes with
    # a UTF-8 BOM so PS 5.1 on the player's machine reads the em-dashes
    # correctly instead of parse-crashing on byte 0x94 — see the helper's
    # comment block for the full encoding-foot-gun explanation.
    $updateEntry = "$InstanceName/.negativezone/update.ps1"
    Add-Ps1ZipEntry -zip $zip -sourcePath $UpdateScriptPath -entryName $updateEntry
    Write-Ok "Bundled update.ps1 -> $updateEntry"

    # Same pattern for backup.ps1, invoked by PostExitCommand. Bundling it
    # alongside update.ps1 keeps the install-time and update-time bits
    # version-locked together — a player can't end up with a fresh backup.ps1
    # against an older update.ps1 or vice versa.
    $backupEntry = "$InstanceName/.negativezone/backup.ps1"
    Add-Ps1ZipEntry -zip $zip -sourcePath $BackupScriptPath -entryName $backupEntry
    Write-Ok "Bundled backup.ps1 -> $backupEntry"

    # Bundle the curated user-prefs manifest as JSON at
    # <InstanceName>/.negativezone/preserve-list.json so update.ps1 (post-
    # swap) and backup.ps1 (snapshot scope) know which pack-shipped files
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
        $preserveTempPath = [System.IO.Path]::GetTempFileName()
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
# player who ran setup.ps1. The auto-merged PR even rewrote modpack.yml
# to point at the broken blob. Refuse to ship anything that can't carry
# the modpack — the deliberately loud throw here is far less painful than
# the FML handshake errors players hit on first connect.
$verifyZip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
try {
    $modEntryPrefix = "$InstanceName/.minecraft/mods/"
    $modEntries = @($verifyZip.Entries | Where-Object {
        $_.FullName.StartsWith($modEntryPrefix) -and $_.FullName.EndsWith('.jar')
    })
} finally { $verifyZip.Dispose() }
if ($modEntries.Count -lt 1) {
    throw ("Built zip '$tempZip' contains 0 entries matching '$modEntryPrefix*.jar'. " +
           "Aborting — refusing to upload an empty pack. " +
           "Did build-instance-from-packwiz.ps1 actually populate .minecraft/mods/, " +
           "and is Get-ChildItem -Force still in the export loop above?")
}
Write-Ok ("Verified: zip carries {0} mod JARs under {1}" -f $modEntries.Count, $modEntryPrefix)

# ─── SHA-256 ───────────────────────────────────────────────────────────────
Write-Step "Computing SHA-256"
$sha = (Get-FileHash $tempZip -Algorithm SHA256).Hash.ToLower()
Write-Ok "sha256 = $sha"

# ─── Upload ────────────────────────────────────────────────────────────────
# --overwrite gated by -Force OR -SkipDriftCheck. Blob preflight already
# refused without -Force; this is defense-in-depth against a concurrent
# publisher creating the blob in the meantime. Test mode always overwrites
# so iterative runs at the same test version don't need -Force.
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
# Upload last so the audit trail (committed modpack.yml) is always present
# before any player can download. If we updated latest.json before the git
# push succeeded and the push then failed, players would download a version
# with no corresponding committed modpack.yml.
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
if ($AllowDowngrade) {
    # Opt-in field — only emitted when the admin explicitly approves rollback.
    # Player-side update.ps1 refuses downgrades unless this is true.
    $manifest['allowDowngrade'] = $true
    Write-Host "    [warn] AllowDowngrade=true: players on newer versions WILL roll back to v$Version" -ForegroundColor Yellow
}

$manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) 'latest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8

# ─── Update modpack.yml + .env + open PR ───────────────────────────────────
# Skipped in test-publish mode — the SHA pin would resolve against origin/main
# which by definition lacks the local packwiz/ changes the test publish is
# validating, silently coupling the test publish to a wrong server snapshot.
if ($SkipDriftCheck) {
    Write-Step "Test-publish mode; skipping modpack.yml + docker-compose.yml rewrite + PR creation."
} else {
    Write-Step "Creating branch '$publishBranch' from origin/main"
    Push-Location $repoRoot
    try {
        # ALWAYS branch from fresh origin/main, NEVER from local HEAD. The
        # old `if (currentBranch -eq 'main') { git checkout -b ... }` was
        # PR #121's root cause: re-running from a leftover publish branch
        # silently stacked the new commit on stale history.
        git checkout -B $publishBranch "origin/main"

        # SHA we just checked out = the packwiz/ snapshot the staging instance
        # was materialized from. Pinning PACKWIZ_URL to this locks the server
        # side to exactly the manifest the client zip ships.
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

        # Atomic SHA + version bump: rewriting PACKWIZ_URL + MOTD in the same
        # commit as modpack.yml means Portainer GitOps redeploys the server
        # with the new MOTD and SHA-pinned mod set; players' next Prism launch
        # fetches the new client zip via PreLaunchCommand. Server + client
        # move together — no kicked-by-mod-mismatch window.
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

        # Bump docs/assets/latest-version.txt to the new version. This is the
        # GitHub-hosted pointer file that prelaunch-check.ps1 polls every
        # launch — when it's ahead of the player's installed version,
        # PreLaunch hard-blocks the launch with an "update required" banner
        # and the iex one-liner. Committing it in the SAME PR as the
        # docker-compose.yml bump means server + client + fallback-proxy MOTD
        # + version pointer all move atomically.
        $latestVersionFile = Join-Path $repoRoot 'docs/assets/latest-version.txt'
        [System.IO.File]::WriteAllText($latestVersionFile, "$Version`n", $utf8NoBom)
        Write-Ok "Bumped docs/assets/latest-version.txt to $Version"

        git add modpack.yml 'docker/proxmox/docker-compose.yml' 'docker/azure/velocity/velocity.toml.tmpl' 'docs/assets/latest-version.txt'
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
- ``modpack.yml`` — the published-version audit record consumed by ``setup.ps1``.
- ``docker/proxmox/docker-compose.yml`` — ``PACKWIZ_URL`` pinned to the new
  packwiz SHA, ``MOTD`` pinned to the new version. Portainer GitOps redeploys
  C2E2 within ~5 min of merge, pulling the same packwiz snapshot that's bundled
  in the client zip above. Server + client move in lockstep.
- ``docker/azure/velocity/velocity.toml.tmpl`` — Velocity fallback ``motd``
  pinned to the new version. Surfaces the current version to players when the
  C2E2 backend is briefly unreachable (deploy-azure.yml redeploys the proxy on
  merge; refresh-env.sh restarts Velocity if velocity.toml content changed).
- ``docs/assets/latest-version.txt`` — single-line version pointer polled on
  every Prism launch by ``prelaunch-check.ps1``. Player launches start hard-
  blocking on the prior version as soon as this merges into ``main`` (served
  via raw.githubusercontent.com).
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
        # FAIL LOUD: a silent warn here strands the PR with no merge intent
        # while latest.json (uploaded ~10 lines below) flips clients onto the
        # new version → server keeps running the previous packwiz snapshot
        # until someone notices and merges manually → "kicked by mod mismatch"
        # window for every joining player. That was tonight's PR #147 root
        # cause. Throwing here halts BEFORE latest.json upload, so player-
        # visible state never gets ahead of a stranded PR. Recovery: enable
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

Halting BEFORE uploading latest.json so player-visible state doesn't flip
to a stranded PR. Branch + zip blob are already uploaded — once the repo
setting is fixed, re-run this script with -Force to resume (it will
force-push the same branch, reuse the existing PR, enable auto-merge,
and finally upload latest.json).
"@
        }
    } finally {
        Pop-Location
    }
}

# ─── Publish latest.json (LAST — only after the audit-trail PR exists) ─────
# Until this point no player-visible state has flipped (versioned zip is
# uploaded but unreferenced). Test mode writes to latest-test.json so
# production setup.ps1 is untouched.
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
