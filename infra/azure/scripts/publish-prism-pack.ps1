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
         default, and drops user-state fields (play time, window layout)
      4. Bundles the instance icon from %APPDATA%\PrismLauncher\icons\ into the
         zip at top-level `icons/<iconKey>.<ext>` so players see the same icon
         (Prism stores icons globally, not inside the instance folder)
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

.EXAMPLE
    ./publish-prism-pack.ps1 -Version 1.0.0

.EXAMPLE
    ./publish-prism-pack.ps1 -InstanceName "C2E2" -Version 2026.06.04
#>

[CmdletBinding()]
param(
    [string]$InstanceName = "Craft to Exile 2",
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$StorageAccount = "stmcminecraftprod",
    [string]$Container = "minecraft-modpack",
    [string]$PrismInstancesDir = "$env:APPDATA\PrismLauncher\instances"
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }

# ─── Preflight ──────────────────────────────────────────────────────────────
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') is required. Install from https://aka.ms/installazurecli"
}

$instancePath = Join-Path $PrismInstancesDir $InstanceName
if (-not (Test-Path $instancePath)) {
    throw "Instance not found at: $instancePath`nCheck -InstanceName and -PrismInstancesDir."
}

if (-not (Test-Path (Join-Path $instancePath 'instance.cfg'))) {
    throw "Path '$instancePath' doesn't look like a Prism instance (no instance.cfg)."
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
# pins memory to a C2E2-friendly default so players don't have to touch
# Prism's Java/memory settings after import. Returns the cleaned content + the
# parsed iconKey so we know which icon to bundle.
function Get-SanitizedInstanceCfg([string]$path) {
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
    $overrides = [ordered]@{
        'AutomaticJava'         = 'true'
        'OverrideJavaLocation'  = 'false'
        'OverrideMemory'        = 'true'
        'MinMemAlloc'           = '512'
        'MaxMemAlloc'           = '6144'
    }

    $iconKey = $null
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
            $value = $matches[2]

            if ($key -eq 'iconKey') { $iconKey = $value }

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

    return [pscustomobject]@{
        Content = ($out -join "`r`n")
        IconKey = $iconKey
    }
}

# Resolves the on-disk icon file for a Prism iconKey. Prism stores icons at
# %APPDATA%\PrismLauncher\icons\<iconKey>.<ext>; the extension varies.
function Find-IconFile([string]$prismRoot, [string]$iconKey) {
    if (-not $iconKey -or $iconKey -eq 'default') { return $null }
    $iconsDir = Join-Path $prismRoot 'icons'
    if (-not (Test-Path $iconsDir)) { return $null }
    foreach ($ext in @('png', 'jpg', 'jpeg', 'gif', 'ico', 'svg')) {
        $candidate = Join-Path $iconsDir "$iconKey.$ext"
        if (Test-Path -LiteralPath $candidate) { return Get-Item -LiteralPath $candidate }
    }
    return $null
}

$instanceCfgPath = Join-Path $instancePath 'instance.cfg'
$sanitized = Get-SanitizedInstanceCfg $instanceCfgPath
$prismRoot = Split-Path $PrismInstancesDir -Parent
$iconFile = Find-IconFile $prismRoot $sanitized.IconKey

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
            try { $writer.Write($sanitized.Content) } finally { $writer.Dispose() }
        } else {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.FullName, $entryName, 'Optimal') | Out-Null
        }
    }

    # Bundle the icon at top-level icons/<iconKey>.<ext>. setup.ps1 copies this
    # to %APPDATA%\PrismLauncher\icons\ on the player's machine.
    if ($iconFile) {
        $iconEntry = "icons/$($iconFile.Name)"
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $iconFile.FullName, $iconEntry, 'Optimal') | Out-Null
        Write-Ok "Bundled icon: $($iconFile.Name)"
    } elseif ($sanitized.IconKey -and $sanitized.IconKey -ne 'default') {
        Write-Host "    [warn] iconKey '$($sanitized.IconKey)' set in instance.cfg but no icon file found in $prismRoot\icons" -ForegroundColor Yellow
    }
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
Write-Step "Uploading to $StorageAccount/$Container/$blobName"
az storage blob upload `
    --account-name $StorageAccount `
    --container-name $Container `
    --name $blobName `
    --file $tempZip `
    --auth-mode login `
    --overwrite true `
    --content-cache-control "public, max-age=2592000, immutable" `
    --output none

# ─── Manifest ──────────────────────────────────────────────────────────────
Write-Step "Updating latest.json manifest"
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

# ─── Update modpack.yml + open PR ──────────────────────────────────────────
Write-Step "Updating modpack.yml and opening PR"
$repoRoot = git rev-parse --show-toplevel
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

Push-Location $repoRoot
try {
    $currentBranch = git branch --show-current
    if ($currentBranch -eq 'main') {
        $branchName = "modpack/v$Version"
        git checkout -b $branchName
    }
    git add modpack.yml
    git commit -m "chore(modpack): publish v$Version`n`nsha256: $sha"
    git push -u origin HEAD
    gh pr create `
        --title "chore(modpack): publish v$Version" `
        --body "Automated modpack publish.`n`n- **Version:** $Version`n- **SHA-256:** ``$sha```n- **Size:** ${sizeMb} MB`n- **Published:** $publishedAt" `
        --base main
    Write-Ok "PR created for modpack v$Version"
} finally {
    Pop-Location
}

# ─── Cleanup ───────────────────────────────────────────────────────────────
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Published successfully." -ForegroundColor Green
Write-Host "  Manifest: https://$StorageAccount.blob.core.windows.net/$Container/latest.json"
Write-Host "  Zip:      https://$StorageAccount.blob.core.windows.net/$Container/$blobName"
Write-Host ""
