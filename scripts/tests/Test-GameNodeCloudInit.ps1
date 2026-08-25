[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$renderer = Join-Path $repositoryRoot 'infra\proxmox\game-node\Render-CloudInit.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\game-node\generic.json'
$palworldProfile = Join-Path $repositoryRoot 'infra\proxmox\game-node\profiles\palworld.json'
$palworldCheckedIn = Join-Path $repositoryRoot 'infra\proxmox\game-node\generated\palworld-cloud-init.yaml'
$testRoot = Join-Path $repositoryRoot 'build\game-node-cloud-init-tests'
$output = Join-Path $testRoot 'fixture-game-cloud-init.yaml'
$palworldOutput = Join-Path $testRoot 'palworld-cloud-init.yaml'

Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $testRoot | Out-Null

$parseTargets = @(
    $renderer
    $PSCommandPath
    (Join-Path $repositoryRoot 'scripts\tests\Test-PalworldStartup.ps1')
)
foreach ($target in $parseTargets) {
    $tokens = $null
    $errors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseFile(
        $target,
        [ref] $tokens,
        [ref] $errors
    )
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failure in ${target}: $($errors -join '; ')"
    }
}

$renderedPath = & $renderer -ProfilePath $fixture -OutputPath $output
if ((Resolve-Path $renderedPath).Path -ne (Resolve-Path $output).Path) {
    throw 'Renderer returned an unexpected output path.'
}

$bytes = [System.IO.File]::ReadAllBytes($output)
if ($bytes.Length -ge 3 -and
    $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    throw 'Rendered cloud-init must not contain a UTF-8 BOM.'
}

$rendered = Get-Content -LiteralPath $output -Raw
$requiredText = @(
    '# Profile: Generic fixture game (fixture-game)'
    'GAME_SLUG=fixture-game'
    'CONTAINER_NAME=fixture-game-server'
    'BACKUP_SOURCE_NAMES="data:config"'
    'BACKUP_CONSISTENCY=fixture-cold-stop'
    'ufw allow 27015/udp'
    'game-backup@fixture-game.timer'
)
foreach ($text in $requiredText) {
    if (-not $rendered.Contains($text)) {
        throw "Rendered cloud-init is missing expected text: $text"
    }
}
if ($rendered -match '@@[A-Z0-9_]+@@') {
    throw "Rendered cloud-init contains unresolved token $($Matches[0])."
}

$invalidProfile = Join-Path $testRoot 'invalid-profile.json'
$configuration = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
$configuration.managementCidrs = @('not-a-cidr')
$configuration | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $invalidProfile -Encoding utf8NoBOM

$validationFailed = $false
try {
    & $renderer -ProfilePath $invalidProfile `
        -OutputPath (Join-Path $testRoot 'invalid.yaml') | Out-Null
}
catch {
    $validationFailed = $_.Exception.Message -like '*CIDR notation*'
}
if (-not $validationFailed) {
    throw 'Renderer accepted an invalid management CIDR.'
}

$renderedPalworldPath = & $renderer -ProfilePath $palworldProfile `
    -OutputPath $palworldOutput
if ((Resolve-Path $renderedPalworldPath).Path -ne
    (Resolve-Path $palworldOutput).Path) {
    throw 'Renderer returned an unexpected Palworld output path.'
}

$palworldRendered = Get-Content -LiteralPath $palworldOutput -Raw
$palworldCommitted = Get-Content -LiteralPath $palworldCheckedIn -Raw
if ($palworldRendered -ne $palworldCommitted) {
    throw 'Checked-in Palworld cloud-init is stale; re-render it from the profile.'
}
foreach ($text in @(
    '# Profile: Palworld (palworld)'
    'CONTAINER_NAME=palworld-server'
    'BACKUP_SOURCE_NAMES="data"'
    'BACKUP_CONSISTENCY=palworld-rest-graceful-stop'
    'BACKUP_STOP_MODE=hook'
    'AZURE_CONTAINER=palworld-backups'
    '/usr/local/libexec/game-backup/palworld'
    'game-backup@palworld.timer'
    'useradd --create-home --shell /bin/bash birdo'
    'birdo ALL=(ALL:ALL) NOPASSWD: ALL'
    'Match User birdo'
)) {
    if (-not $palworldRendered.Contains($text)) {
        throw "Rendered Palworld cloud-init is missing expected text: $text"
    }
}
if ($palworldRendered -match '(?m)^\s*-\s+ufw allow 8211/udp') {
    throw 'Palworld cloud-init must not open a public player port.'
}

Write-Output "Cloud-init renderer tests passed: $output and $palworldOutput"
