#requires -Version 7.0
<#
.SYNOPSIS
    Export a Prism Launcher instance and publish it to Azure Blob storage so
    player setup.ps1 can pull it in seconds instead of waiting through
    a CurseForge download.

.DESCRIPTION
    Steps:
      1. Reads the Prism instance directory directly from your local Prism install
      2. Zips it into a distributable pack, excluding user-specific files
         (saves, logs, screenshots, options.txt, etc.) while keeping mods,
         configs, resourcepacks, shaderpacks, servers.dat, and instance.cfg
         (Java args + memory settings)
      3. Sanitizes instance.cfg so it imports cleanly on any player's machine:
         strips your local JavaPath/JavaSignature/etc., sets AutomaticJava=true
         so Prism picks the right Java itself, pins memory to a C2E2-friendly
         default, forces iconKey=<IconKey> so players see the branded icon, and
         drops user-state fields (play time, window layout)
      4. Bundles the repo-tracked instance icon (default: cte2-icon.png next to
         this script) into the zip at top-level `icons/<IconKey>.<ext>` so the
         icon is reproducible regardless of what the admin's local Prism has
         set (Prism stores icons globally at %APPDATA%\PrismLauncher\icons\,
         not inside the instance folder)
      5. Computes SHA-256 of the zip
      6. Uploads the versioned zip + an updated `latest.json` manifest to the
         `minecraft-modpack` public-read blob container
      7. Sets cache headers so updates propagate quickly

    Authenticates via your existing Azure CLI session (`az login`). You need
    Storage Blob Data Contributor on the container — your user account already
    has this if you can deploy the rest of the stack.

.PARAMETER InstanceName
    The exact folder name of the instance in Prism's instances directory.
    Defaults to "Craft to Exile 2".

.PARAMETER Version
    Semantic-ish version string for this publish, e.g. "1.0.0" or "2026.06.04".
    Used as the blob filename suffix and stored in latest.json.

.PARAMETER StorageAccount
    Azure Storage account name. Defaults to stmcminecraftprod.

.PARAMETER Container
    Blob container name. Defaults to minecraft-modpack.

.PARAMETER PrismInstancesDir
    Path to Prism's instances directory. Defaults to %APPDATA%\PrismLauncher\instances.

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

.EXAMPLE
    ./publish-prism-pack.ps1 -Version 1.0.0

.EXAMPLE
    ./publish-prism-pack.ps1 -InstanceName "C2E2" -Version 2026.06.04

.EXAMPLE
    # Re-publish v1.0.0 after a botched first attempt
    ./publish-prism-pack.ps1 -Version 1.0.0 -Force
#>

[CmdletBinding()]
param(
    [string]$InstanceName = "Craft to Exile 2",
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$StorageAccount = "stmcminecraftprod",
    [string]$Container = "minecraft-modpack",
    [string]$PrismInstancesDir = "$env:APPDATA\PrismLauncher\instances",
    [string]$IconPath = (Join-Path $PSScriptRoot 'cte2-icon.png'),
    [string]$IconKey = 'cte2',
    [switch]$Force
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

$instancePath = Join-Path $PrismInstancesDir $InstanceName
if (-not (Test-Path $instancePath)) {
    throw "Instance not found at: $instancePath`nCheck -InstanceName and -PrismInstancesDir."
}

if (-not (Test-Path (Join-Path $instancePath 'instance.cfg'))) {
    throw "Path '$instancePath' doesn't look like a Prism instance (no instance.cfg)."
}

# ─── Git preflight ─────────────────────────────────────────────────────────
# Catch the two failure modes that produced PR #121's merge conflict:
#   1. Working tree dirty (would mix unrelated edits into the auto-PR).
#   2. `origin/modpack/v<Version>` already exists (we'd silently stack a new
#      commit on a stale publish branch, or two parallel publishes would
#      clobber each other).
# Both fail fast, BEFORE the expensive zip + blob upload, so a bad git state
# doesn't waste a multi-minute publish.
$repoRoot = git rev-parse --show-toplevel
$publishBranch = "modpack/v$Version"

Push-Location $repoRoot
try {
    $dirty = (git status --porcelain) -join "`n"
    if ($dirty) {
        throw "Working tree at '$repoRoot' is not clean. Commit or stash these changes before publishing:`n$dirty"
    }

    Write-Step "Fetching origin (refs + prune)"
    git fetch origin --prune

    $remoteRef = (git for-each-ref --format='%(refname)' "refs/remotes/origin/$publishBranch" | Out-String).Trim()
    $expectedRemoteSha = ''
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
} finally {
    Pop-Location
}

# Blob preflight: the versioned zip lives at an immutable URL (Cache-Control
# headers tell CDNs it never changes), so overwriting one with different bytes
# is a player-visible correctness hazard. Refuse without -Force.
Write-Step "Checking for existing blob 'c2e2-v$Version.zip'"
$blobExistsJson = (az storage blob exists `
    --account-name $StorageAccount `
    --container-name $Container `
    --name "c2e2-v$Version.zip" `
    --auth-mode login `
    --output json | Out-String).Trim()
$blobAlreadyExists = ($blobExistsJson | ConvertFrom-Json).exists
if ($blobAlreadyExists) {
    if (-not $Force) {
        throw "Blob 'c2e2-v$Version.zip' already exists in '$StorageAccount/$Container'. Pick a new -Version or re-run with -Force to overwrite."
    }
    Write-Host "    [warn] Blob 'c2e2-v$Version.zip' already exists; -Force will overwrite it" -ForegroundColor Yellow
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
function Get-SanitizedInstanceCfg([string]$path, [string]$iconKey) {
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

    # Fields whose values we override to a known-good default. Order: existing
    # lines get rewritten in place; missing fields get appended to [General].
    # 8192 MB matches C2E2's recommended ceiling — players on 8 GB-total
    # systems should lower it to 4096 in Prism after install.
    $overrides = [ordered]@{
        'AutomaticJava'         = 'true'
        'OverrideJavaLocation'  = 'false'
        'OverrideMemory'        = 'true'
        'MinMemAlloc'           = '512'
        'MaxMemAlloc'           = '8192'
        'iconKey'               = $iconKey
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
$sanitizedCfg = Get-SanitizedInstanceCfg $instanceCfgPath $IconKey

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
# --overwrite is gated by -Force: the blob preflight already refused if the
# blob exists without -Force, so this is defense-in-depth against a concurrent
# publisher creating the blob between preflight and upload.
$overwriteFlag = if ($Force) { 'true' } else { 'false' }
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

# ─── Update modpack.yml + open PR ──────────────────────────────────────────
Write-Step "Creating branch '$publishBranch' from origin/main"
Push-Location $repoRoot
try {
    # ALWAYS branch from fresh origin/main — never from local HEAD. The old
    # `if (currentBranch -eq 'main') { git checkout -b ... }` was the root
    # cause of PR #121's conflict: re-running the script from a leftover
    # publish branch silently stacked the new commit on stale history.
    git checkout -B $publishBranch "origin/main"

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

    git add modpack.yml
    git commit -m "chore(modpack): publish v$Version`n`nsha256: $sha"

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

# ─── Publish latest.json (LAST — only after the audit-trail PR exists) ─────
# Up until this point, no player-visible state has been updated: the versioned
# zip is uploaded but unreferenced (latest.json still points at the previous
# version). Only after the git push + PR succeed do we flip latest.json to
# advertise the new version. This guarantees that players never see a version
# without a corresponding committed modpack.yml.
Write-Step "Uploading latest.json"
az storage blob upload `
    --account-name $StorageAccount `
    --container-name $Container `
    --name 'latest.json' `
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
Write-Host "Published successfully." -ForegroundColor Green
Write-Host "  Manifest: https://$StorageAccount.blob.core.windows.net/$Container/latest.json"
Write-Host "  Zip:      https://$StorageAccount.blob.core.windows.net/$Container/$blobName"
Write-Host ""
