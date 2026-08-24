#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

$retiredWorkflows = @(
    '.github/workflows/release-setup-script.yml',
    '.github/workflows/release-migrate-script.yml',
    '.github/workflows/protect-latest-release.yml',
    '.github/workflows/test-setup-e2e.yml'
)
foreach ($relative in $retiredWorkflows) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $relative)) {
        throw "Retired workflow still exists: $relative"
    }
}

$recoveryAssets = @(
    'docs/assets/setup.ps1',
    'docs/assets/update.ps1',
    'docs/assets/backup.ps1',
    'docs/assets/prelaunch-check.ps1',
    'docs/assets/migrate-settings.ps1'
)
foreach ($relative in $recoveryAssets) {
    $path = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Immutable legacy releases still require recovery asset: $relative"
    }
    $header = (Get-Content -LiteralPath $path -TotalCount 12) -join "`n"
    if ($header -notmatch 'ARCHIVED RECOVERY ONLY') {
        throw "Recovery asset is not clearly archived: $relative"
    }
}

$legacyPointer = Join-Path $repoRoot 'docs\assets\latest-version.txt'
if (-not (Test-Path -LiteralPath $legacyPointer) -or
    [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $legacyPointer -Raw))) {
    throw 'Frozen legacy latest-version.txt recovery pointer is missing or empty.'
}

$activeFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot '.github\workflows') -File -Filter '*.yml'
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -File -Filter '*.md' |
        Where-Object Name -ne 'legacy-recovery.md'
    Get-Item -LiteralPath (Join-Path $repoRoot 'ops\publish-runbook.md')
    Get-Item -LiteralPath (Join-Path $repoRoot 'packwiz\README.md')
    Get-Item -LiteralPath (Join-Path $repoRoot 'games\minecraft\client\scripts\install.ps1')
    Get-Item -LiteralPath (Join-Path $repoRoot 'infra\azure\scripts\publish-prism-pack.ps1')
)
$forbidden = @(
    'releases/latest/download/setup\.ps1',
    'releases/download/setup-v[^/\s]*/setup\.ps1',
    'releases/download/migrate-v[^/\s]*/migrate-settings\.ps1',
    'raw\.githubusercontent\.com/camcast3/MinecraftInfra/main/docs/assets/(setup|update|backup|prelaunch-check|migrate-settings)\.ps1',
    'release-setup-script\.yml',
    'release-migrate-script\.yml',
    'protect-latest-release\.yml',
    'test-setup-e2e\.yml'
)
foreach ($file in $activeFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $forbidden) {
        if ($content -match $pattern) {
            throw "Deprecated client distribution reference '$pattern' remains in $($file.FullName)"
        }
    }
}

foreach ($doc in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -File -Filter '*.md') {
    $content = Get-Content -LiteralPath $doc.FullName -Raw
    foreach ($match in [regex]::Matches($content, '{%\s*link\s+([^\s%]+)\s*%}')) {
        $target = Join-Path (Join-Path $repoRoot 'docs') $match.Groups[1].Value
        if (-not (Test-Path -LiteralPath $target)) {
            throw "Broken Jekyll link in $($doc.Name): $($match.Groups[1].Value)"
        }
    }
}

Write-Host 'Client distribution retirement and documentation path checks passed.'
