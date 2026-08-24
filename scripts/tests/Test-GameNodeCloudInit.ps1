[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$renderer = Join-Path $repositoryRoot 'infra\proxmox\game-node\Render-CloudInit.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\game-node\generic.json'
$testRoot = Join-Path $repositoryRoot 'build\game-node-cloud-init-tests'
$output = Join-Path $testRoot 'fixture-game-cloud-init.yaml'

Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $testRoot | Out-Null

$parseTargets = @(
    $renderer
    $PSCommandPath
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

Write-Output "Cloud-init renderer tests passed: $output"
