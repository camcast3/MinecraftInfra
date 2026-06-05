#requires -Version 7.0
<#
.SYNOPSIS
    Export a Prism Launcher instance and publish it to Azure Blob storage so
    player setup.ps1 can pull it in seconds instead of waiting through
    a CurseForge download.

.DESCRIPTION
    Steps:
      1. Reads the Prism instance directory directly from your local Prism install
      2. Zips it into a Prism-compatible instance export
      3. Computes SHA-256 of the zip
      4. Uploads the versioned zip + an updated `latest.json` manifest to the
         `minecraft-modpack` public-read blob container
      5. Sets cache headers so updates propagate quickly

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

# Prism's own export format is just the instance folder zipped with the
# instance folder name as the root entry. Recreate that here.
$parentDir = Split-Path $instancePath -Parent
Push-Location $parentDir
try {
    Compress-Archive -Path $InstanceName -DestinationPath $tempZip -CompressionLevel Optimal
} finally {
    Pop-Location
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

# ─── Cleanup ───────────────────────────────────────────────────────────────
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Published successfully." -ForegroundColor Green
Write-Host "  Manifest: https://$StorageAccount.blob.core.windows.net/$Container/latest.json"
Write-Host "  Zip:      https://$StorageAccount.blob.core.windows.net/$Container/$blobName"
Write-Host ""
