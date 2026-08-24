[CmdletBinding()]
param(
    [switch] $AzureWhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..')
)

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    Write-Host "RUN: $Command $($Arguments -join ' ')"
    $previousPythonUtf8 = $env:PYTHONUTF8
    if ($Command -eq 'az') {
        $env:PYTHONUTF8 = '1'
    }
    try {
        $output = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:PYTHONUTF8 = $previousPythonUtf8
    }
    if ($exitCode -ne 0) {
        throw "$Command failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }
    $suppressOutput = $Command -eq 'az' -and $Arguments -contains '--stdout'
    if ($output.Count -gt 0 -and -not $suppressOutput) {
        Write-Host ($output -join [Environment]::NewLine)
    }
}

Push-Location $repositoryRoot
try {
    Write-Host '=== Shared contracts, secrets, and public exposure policy ==='
    & (Join-Path $repositoryRoot 'scripts/Validate-GameContracts.ps1')
    & (Join-Path $repositoryRoot 'scripts/tests/Test-GameContracts.ps1')
    & (Join-Path $repositoryRoot 'scripts/tests/Test-AzureEdge.ps1')

    Write-Host '=== Palworld pre-production validation (first rollout) ==='
    Invoke-Native -Command 'bash' -Arguments @(
        'scripts/tests/Test-GameBackups.sh'
    )
    & (Join-Path $repositoryRoot 'scripts/tests/Test-GameNodeCloudInit.ps1')
    & (Join-Path $repositoryRoot 'scripts/tests/Test-EdgeForwarding.ps1')
    & (Join-Path $repositoryRoot 'scripts/tests/Test-PalworldStartup.ps1')

    Write-Host '=== Windrose pre-production validation (second rollout) ==='
    Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm',
        '--volume', "$($repositoryRoot.Replace('\', '/')):/repo",
        '--workdir', '/repo',
        'ubuntu:24.04',
        'bash', 'scripts/tests/Test-GameBackupLifecycle.sh'
    )
    & (Join-Path $repositoryRoot 'scripts/tests/Test-ComposeLifecycle.ps1')

    Write-Host '=== Azure infrastructure compilation ==='
    $bicepOutput = Join-Path $repositoryRoot 'build/multigame-rollout/bicep/main.json'
    New-Item -ItemType Directory -Path (Split-Path $bicepOutput) -Force | Out-Null
    Invoke-Native -Command 'az' -Arguments @(
        'bicep', 'build',
        '--file', (Join-Path $repositoryRoot 'infra/azure/main.bicep'),
        '--outfile', $bicepOutput,
        '--only-show-errors'
    )

    if ($AzureWhatIf) {
        Write-Host '=== Read-only Azure what-if (no deployment) ==='
        Invoke-Native -Command 'az' -Arguments @(
            'deployment', 'group', 'what-if',
            '--resource-group', 'rg-minecraft-prod',
            '--template-file', (Join-Path $repositoryRoot 'infra/azure/main.bicep'),
            '--parameters', (Join-Path $repositoryRoot 'infra/azure/parameters/prod.bicepparam'),
            '--result-format', 'ResourceIdOnly',
            '--no-pretty-print',
            '--only-show-errors'
        )
    } else {
        Write-Host 'SKIP LIVE-ACCOUNT READ: Azure what-if requires -AzureWhatIf; no deployment is ever performed.'
    }
} finally {
    Pop-Location
}

Write-Host 'All safe multi-game rollout validation completed. Live-only gates remain explicitly unverified.'
