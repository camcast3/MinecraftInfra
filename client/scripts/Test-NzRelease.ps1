#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $NzExe,
    [Parameter(Mandatory)][string] $Metadata,
    [Parameter(Mandatory)][string] $Checksums
)

$ErrorActionPreference = 'Stop'
$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Could not resolve the repository root.' }
$NzExe = (Resolve-Path -LiteralPath $NzExe).Path
$Metadata = (Resolve-Path -LiteralPath $Metadata).Path
$Checksums = (Resolve-Path -LiteralPath $Checksums).Path

$release = Get-Content -LiteralPath $Metadata -Raw -Encoding UTF8 | ConvertFrom-Json
if ($release.schemaVersion -ne 1 -or $release.tag -notmatch '^nz-v[0-9a-f]{12}$') {
    throw 'Invalid immutable nz release identity.'
}
if ($release.binary.name -ne 'nz.exe' -or
    $release.binary.url -notmatch "/releases/download/$([regex]::Escape($release.tag))/nz\.exe$") {
    throw 'nz-release.json does not point to its immutable release asset.'
}
if ($release.compatibility.os -ne 'windows' -or
    $release.compatibility.arch -ne 'amd64' -or
    -not $release.compatibility.modpackVersion -or
    $release.compatibility.manifestSchema -ne 1 -or
    $release.compatibility.preserveListSchema -ne 1 -or
    $release.compatibility.transactionSchema -ne 1) {
    throw 'nz-release.json compatibility metadata is incomplete.'
}

$actualHash = (Get-FileHash -LiteralPath $NzExe -Algorithm SHA256).Hash.ToLowerInvariant()
$actualSize = (Get-Item -LiteralPath $NzExe).Length
if ($actualHash -ne ([string]$release.binary.sha256).ToLowerInvariant()) {
    throw 'nz-release.json SHA-256 does not match nz.exe.'
}
if ($actualSize -ne [int64]$release.binary.sizeBytes) {
    throw 'nz-release.json size does not match nz.exe.'
}
$checksumLine = (Get-Content -LiteralPath $Checksums -Raw).Trim()
if ($checksumLine -ne "$actualHash *nz.exe") {
    throw 'SHA256SUMS does not match nz.exe.'
}

$versionOutput = (& $NzExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch [regex]::Escape([string]$release.version)) {
    throw "Static launch failed or reported the wrong version: $versionOutput"
}
$helpOutput = (& $NzExe --help 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $helpOutput -notmatch 'NegativeZone Minecraft client CLI') {
    throw 'Static --help launch failed.'
}

$work = Join-Path $repoRoot '.artifacts\nz-release-validation'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $localMetadata = Join-Path $work 'nz-release.json'
    $localAppData = Join-Path $work 'localappdata'
    $release.binary.url = $NzExe
    $release | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $localMetadata -Encoding UTF8 -NoNewline

    $oldLocalAppData = $env:LOCALAPPDATA
    $oldReleaseURL = $env:NEGATIVEZONE_NZ_RELEASE_URL
    $oldSkipWinget = $env:NEGATIVEZONE_SKIP_WINGET
    $oldSkipSetup = $env:NEGATIVEZONE_SKIP_SETUP
    try {
        $env:LOCALAPPDATA = $localAppData
        $env:NEGATIVEZONE_NZ_RELEASE_URL = $localMetadata
        $env:NEGATIVEZONE_SKIP_WINGET = '1'
        $env:NEGATIVEZONE_SKIP_SETUP = '1'
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw "install.ps1 canary failed with exit code $LASTEXITCODE"
        }
    } finally {
        $env:LOCALAPPDATA = $oldLocalAppData
        $env:NEGATIVEZONE_NZ_RELEASE_URL = $oldReleaseURL
        $env:NEGATIVEZONE_SKIP_WINGET = $oldSkipWinget
        $env:NEGATIVEZONE_SKIP_SETUP = $oldSkipSetup
    }

    $installed = Join-Path $localAppData 'NegativeZone\nz.exe'
    if (-not (Test-Path -LiteralPath $installed) -or
        (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant() -ne $actualHash) {
        throw 'Installer canary did not atomically install the verified nz.exe.'
    }

    $badMetadata = Join-Path $work 'nz-release-bad.json'
    $badAppData = Join-Path $work 'bad-localappdata'
    $badInstallDir = Join-Path $badAppData 'NegativeZone'
    $badInstalled = Join-Path $badInstallDir 'nz.exe'
    New-Item -ItemType Directory -Path $badInstallDir -Force | Out-Null
    [IO.File]::WriteAllText($badInstalled, 'previous-good-binary', [Text.Encoding]::ASCII)
    $release.binary.sha256 = '0' * 64
    $release | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $badMetadata -Encoding UTF8 -NoNewline
    try {
        $env:LOCALAPPDATA = $badAppData
        $env:NEGATIVEZONE_NZ_RELEASE_URL = $badMetadata
        $env:NEGATIVEZONE_SKIP_WINGET = '1'
        $env:NEGATIVEZONE_SKIP_SETUP = '1'
        $badOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1') 2>&1
        $badExit = $LASTEXITCODE
        if ($badExit -eq 0 -or
            [IO.File]::ReadAllText($badInstalled, [Text.Encoding]::ASCII) -ne 'previous-good-binary') {
            throw "Installer accepted a corrupt checksum: $($badOutput -join [Environment]::NewLine)"
        }
    } finally {
        $env:LOCALAPPDATA = $oldLocalAppData
        $env:NEGATIVEZONE_NZ_RELEASE_URL = $oldReleaseURL
        $env:NEGATIVEZONE_SKIP_WINGET = $oldSkipWinget
        $env:NEGATIVEZONE_SKIP_SETUP = $oldSkipSetup
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Validated immutable nz release $($release.tag) ($actualHash)."
$global:LASTEXITCODE = 0
