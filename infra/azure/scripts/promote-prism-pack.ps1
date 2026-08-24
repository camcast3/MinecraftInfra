#requires -Version 7.0
<#
.SYNOPSIS
    Promote an immutable modpack manifest to the stable client pointers.

.DESCRIPTION
    This script is intentionally separate from candidate packaging. It is run
    only after the publish PR has merged and the public Minecraft status gate
    reports the expected version. It validates the committed modpack.yml
    against the immutable manifest, checks the versioned zip metadata, then
    updates latest.json and latest-version.txt.
#>

[CmdletBinding()]
param(
    [string] $ModpackFile,
    [string] $StorageAccount = 'stmcminecraftprod',
    [string] $Container = 'minecraft-modpack',
    [switch] $AllowDowngrade
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $ModpackFile) { $ModpackFile = Join-Path $repoRoot 'modpack.yml' }

function Read-YamlScalar([string] $Name, [string] $Content) {
    $match = [regex]::Match($Content, "(?m)^$([regex]::Escape($Name)):\s*['""]?([^'""\r\n]+)['""]?\s*$")
    if (-not $match.Success) { throw "modpack.yml is missing '$Name'." }
    return $match.Groups[1].Value.Trim()
}

$content = Get-Content -LiteralPath $ModpackFile -Raw -Encoding UTF8
$version = Read-YamlScalar 'version' $content
$sha256 = Read-YamlScalar 'sha256' $content
$zipURL = Read-YamlScalar 'url' $content
$manifestURL = Read-YamlScalar 'manifest' $content

$expectedManifestURL = "https://$StorageAccount.blob.core.windows.net/$Container/c2e2-v$version.json"
$expectedZipURL = "https://$StorageAccount.blob.core.windows.net/$Container/c2e2-v$version.zip"
if ($manifestURL -ne $expectedManifestURL -or $zipURL -ne $expectedZipURL) {
    throw 'modpack.yml does not point to the expected immutable versioned assets.'
}

$work = Join-Path $repoRoot '.artifacts\promotion'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$manifestPath = Join-Path $work "c2e2-v$version.json"
$zipPath = Join-Path $work "c2e2-v$version.zip"
$preservePath = Join-Path $work "c2e2-v$version-preserve-list.json"
$versionPath = Join-Path $work 'latest-version.txt'
try {
    Invoke-WebRequest -Uri $manifestURL -OutFile $manifestPath -UseBasicParsing
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.version -ne $version -or
        $manifest.url -ne $zipURL -or $manifest.sha256 -ne $sha256) {
        throw 'Immutable manifest does not match committed modpack.yml.'
    }
    if ($manifest.compatibility.minecraft -ne '1.20.1' -or
        $manifest.compatibility.javaMajor -ne 17 -or
        $manifest.compatibility.manifestSchema -ne 1 -or
        $manifest.compatibility.preserveListSchema -ne 1 -or
        $manifest.compatibility.transactionSchema -ne 1) {
        throw 'Immutable manifest compatibility metadata is incomplete.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.preserveListUrl)) {
        throw 'Immutable manifest is missing preserveListUrl.'
    }
    Invoke-WebRequest -Uri $manifest.preserveListUrl -OutFile $preservePath -UseBasicParsing
    $preserveManifest = Get-Content -LiteralPath $preservePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($preserveManifest.version -ne 1 -or $null -eq $preserveManifest.preserve) {
        throw 'Immutable preserve manifest is invalid.'
    }
    if ($AllowDowngrade) {
        $manifest | Add-Member -NotePropertyName allowDowngrade -NotePropertyValue $true -Force
        [IO.File]::WriteAllText(
            $manifestPath,
            ($manifest | ConvertTo-Json -Depth 10),
            [Text.UTF8Encoding]::new($false)
        )
    }

    $compose = Get-Content -LiteralPath (Join-Path $repoRoot 'docker\proxmox\docker-compose.yml') -Raw
    $composeSHA = [regex]::Match(
        $compose,
        '(?m)^\s*PACKWIZ_URL:\s*"https://raw\.githubusercontent\.com/camcast3/MinecraftInfra/([^/"]+)/packwiz/pack\.toml"\s*$'
    )
    $composeVersion = [regex]::Match($compose, "(?m)^\s*MOTD:\s*`"Craft to Exile 2 v([^`"]+)`"\s*$")
    if (-not $composeSHA.Success -or $composeSHA.Groups[1].Value -ne $manifest.sourceCommit) {
        throw 'Server PACKWIZ_URL does not match the immutable manifest source commit.'
    }
    if (-not $composeVersion.Success -or $composeVersion.Groups[1].Value -ne $version) {
        throw 'Server MOTD does not match the promoted version.'
    }

    $velocity = Get-Content -LiteralPath (Join-Path $repoRoot 'docker\azure\velocity\velocity.toml.tmpl') -Raw
    $velocityVersion = [regex]::Match($velocity, "(?m)^motd\s*=\s*`"Craft to Exile 2 v([^`"]+)`"\s*$")
    if (-not $velocityVersion.Success -or $velocityVersion.Groups[1].Value -ne $version) {
        throw 'Velocity fallback MOTD does not match the promoted version.'
    }

    $head = Invoke-WebRequest -Uri $zipURL -Method Head -UseBasicParsing
    $remoteLength = [int64]$head.Headers.'Content-Length'
    if ($remoteLength -ne [int64]$manifest.sizeBytes) {
        throw "Immutable zip size mismatch: manifest=$($manifest.sizeBytes), remote=$remoteLength."
    }
    Invoke-WebRequest -Uri $zipURL -OutFile $zipPath -UseBasicParsing
    $downloadedSHA = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadedSHA -ne ([string]$manifest.sha256).ToLowerInvariant()) {
        throw "Immutable zip checksum mismatch: manifest=$($manifest.sha256), downloaded=$downloadedSHA."
    }

    [IO.File]::WriteAllText($versionPath, "$version`n", [Text.UTF8Encoding]::new($false))
    & az storage blob upload `
        --account-name $StorageAccount `
        --container-name $Container `
        --name latest.json `
        --file $manifestPath `
        --auth-mode login `
        --overwrite true `
        --content-type 'application/json' `
        --content-cache-control 'no-cache' `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload latest.json (az exit code $LASTEXITCODE)."
    }
    & az storage blob upload `
        --account-name $StorageAccount `
        --container-name $Container `
        --name latest-version.txt `
        --file $versionPath `
        --auth-mode login `
        --overwrite true `
        --content-type 'text/plain' `
        --content-cache-control 'no-cache' `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload latest-version.txt (az exit code $LASTEXITCODE)."
    }
} finally {
    Remove-Item -LiteralPath $manifestPath, $zipPath, $preservePath, $versionPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Promoted immutable modpack v$version to latest.json and latest-version.txt."
