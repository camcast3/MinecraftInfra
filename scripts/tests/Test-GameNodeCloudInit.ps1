[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$gameNodeRoot = Join-Path $repositoryRoot 'platform/proxmox/game-node'
$renderScript = Join-Path $gameNodeRoot 'Render-CloudInit.ps1'
$testRoot = Join-Path $repositoryRoot 'build/multigame-rollout/cloud-init'

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $output = @(& $Command @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Command failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }
    return $output -join [Environment]::NewLine
}

if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

foreach ($profile in @('palworld', 'windrose')) {
    $renderedPath = Join-Path $testRoot "$profile-cloud-init.yaml"
    & $renderScript -Profile $profile -OutputPath $renderedPath | Out-Null
    $checkedInPath = Join-Path $gameNodeRoot "generated/$profile-cloud-init.yaml"

    $rendered = Get-Content -LiteralPath $renderedPath -Raw -Encoding UTF8
    $checkedIn = Get-Content -LiteralPath $checkedInPath -Raw -Encoding UTF8
    if ($rendered -ne $checkedIn) {
        throw "Checked-in $profile cloud-init is stale; re-render it with Render-CloudInit.ps1."
    }
    if ($rendered -match '@@[A-Z0-9_]+@@') {
        throw "$profile cloud-init contains an unresolved template token."
    }
    if ($rendered -match '(?m)^\s*-\s+ufw allow (?:8211|7777)/(?:tcp|udp)') {
        throw "$profile cloud-init opens a public player port; ingress belongs at Azure."
    }

    $profileJson = Get-Content -LiteralPath (
        Join-Path $gameNodeRoot "profiles/$profile.json"
    ) -Raw -Encoding UTF8 | ConvertFrom-Json
    $nodeContract = Get-Content -LiteralPath (
        Join-Path $repositoryRoot "platform/contracts/nodes/$profile-proxmox.json"
    ) -Raw -Encoding UTF8 | ConvertFrom-Json
    $gameContract = Get-Content -LiteralPath (
        Join-Path $repositoryRoot "platform/contracts/games/$profile.json"
    ) -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($profileJson.dataRoot -ne $nodeContract.dataRoot) {
        throw "$profile profile and node contract disagree on dataRoot."
    }
    if ($gameContract.nodeId -ne $nodeContract.nodeId) {
        throw "$profile game and node contracts are not linked."
    }
    if ($profileJson.azureBackupContainer -ne "$profile-backups" -or
        $gameContract.backupPolicy.targets -notcontains 'azure-blob-cold-90d') {
        throw "$profile profile does not match its contracted Azure backup container."
    }
}

$nativeCloudInit = Get-Command 'cloud-init' -ErrorAction SilentlyContinue
if ($null -ne $nativeCloudInit) {
    foreach ($profile in @('palworld', 'windrose')) {
        Invoke-Native -Command $nativeCloudInit.Source -Arguments @(
            'schema', '--config-file', (Join-Path $testRoot "$profile-cloud-init.yaml")
        ) | Out-Null
    }
} else {
    $mount = "$($repositoryRoot.Replace('\', '/')):/repo:ro"
    Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm', '--volume', $mount,
        'ubuntu:24.04',
        'bash', '-ceu',
        'export DEBIAN_FRONTEND=noninteractive; ' +
        'apt-get update -qq; ' +
        'apt-get install -y -qq cloud-init >/dev/null; ' +
        'cloud-init schema --config-file ' +
        '/repo/build/multigame-rollout/cloud-init/palworld-cloud-init.yaml; ' +
        'cloud-init schema --config-file ' +
        '/repo/build/multigame-rollout/cloud-init/windrose-cloud-init.yaml'
    ) | Out-Null
}

Write-Host 'Rendered Palworld and Windrose cloud-init matches source and passes cloud-init schema.'
