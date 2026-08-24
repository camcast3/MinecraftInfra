[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$buildRoot = Join-Path $repositoryRoot 'build\azure-backup-tests'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-NativeText {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $output = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }
    return $output -join [Environment]::NewLine
}

Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null

$bicepFiles = @(
    'infra/azure/main.bicep',
    'infra/azure/modules/backup-storage.bicep',
    'infra/azure/modules/budget.bicep',
    'infra/azure/modules/metric-alerts.bicep',
    'infra/azure/modules/storage.bicep'
)
foreach ($relativePath in $bicepFiles) {
    $source = Join-Path $repositoryRoot $relativePath
    $output = Join-Path $buildRoot (
        ($relativePath -replace '[\\/]', '-') -replace '\.bicep$', '.json'
    )
    Invoke-NativeText -Command 'az' -Arguments @(
        'bicep', 'build', '--file', $source, '--outfile', $output
    ) | Out-Null
}

$mainText = Get-Content (Join-Path $repositoryRoot 'infra/azure/main.bicep') -Raw
$backupText = Get-Content (
    Join-Path $repositoryRoot 'infra/azure/modules/backup-storage.bicep'
) -Raw
$metricText = Get-Content (
    Join-Path $repositoryRoot 'infra/azure/modules/metric-alerts.bicep'
) -Raw
$budgetText = Get-Content (
    Join-Path $repositoryRoot 'infra/azure/modules/budget.bicep'
) -Raw
$prodText = Get-Content (
    Join-Path $repositoryRoot 'infra/azure/parameters/prod.bicepparam'
) -Raw

Assert-True ($mainText.Contains("param palworldBackupSpObjectId string = ''")) `
    'Palworld backup writer must default to empty.'
Assert-True ($mainText.Contains("param windroseBackupSpObjectId string = ''")) `
    'Windrose backup writer must default to empty.'
Assert-True (-not $prodText.Contains('param palworldBackupSpObjectId')) `
    'Production must not enable the Palworld backup container yet.'
Assert-True (-not $prodText.Contains('param windroseBackupSpObjectId')) `
    'Production must not enable the Windrose backup container yet.'
Assert-True ($backupText.Contains('allowBlobPublicAccess: false')) `
    'Backup storage must disable anonymous blob access.'
Assert-True ($backupText.Contains('allowSharedKeyAccess: false')) `
    'Backup storage must require OAuth.'
Assert-True ($backupText.Contains('scope: gameContainers[index]')) `
    'Backup writers must be scoped to their matching containers.'
Assert-True (
    $backupText.Contains(
        "name: guid(storageAccount.id, game.containerName, storageBlobDataContributorRoleId)"
    )
) 'Writer role IDs must remain stable per container.'
Assert-True ($metricText.Contains("'OAuth'")) `
    'Ingress policy must filter to OAuth writes.'
Assert-True ($metricText.Contains("'Primary'")) `
    'Ingress policy must filter to primary storage.'
Assert-True ($metricText.Contains("'PutBlock'") -and $metricText.Contains("'PutBlob'")) `
    'Ingress policy must cover expected block and blob writes.'
Assert-True ($metricText.Contains("windowSize: 'PT1H'")) `
    'Ingress policy must use the one-hour window.'
Assert-True ($budgetText.Contains("thresholdType: 'Forecasted'")) `
    'Budget policy must include a forecast notification.'

$environmentNames = @(
    'TS_AUTHKEY',
    'CF_API_KEY',
    'VELOCITY_FORWARDING_SECRET',
    'RCON_PASSWORD',
    'AZURE_TENANT_ID',
    'AZURE_CLIENT_ID',
    'AZURE_CLIENT_SECRET',
    'BACKUP_STORAGE_ACCOUNT',
    'TS_HOSTNAME'
)
$savedEnvironment = @{}
try {
    foreach ($name in $environmentNames) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, "test-$($name.ToLowerInvariant())")
    }

    $composePath = Join-Path $repositoryRoot 'docker/proxmox/docker-compose.yml'
    $compose = Invoke-NativeText -Command 'docker' -Arguments @(
        'compose', '-f', $composePath, 'config', '--format', 'json'
    ) | ConvertFrom-Json
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
}

$azureBackup = $compose.services.'backup-azure'
$health = $compose.services.'backup-health'
Assert-True ($azureBackup.environment.RCLONE_DEST_DIR -eq 'c2e2-backups') `
    'C2E2 must write to its isolated container.'
Assert-True (
    $azureBackup.environment.RCLONE_CONFIG_AZBLOB_ACCOUNT -eq
        'test-backup_storage_account'
) 'C2E2 must use BACKUP_STORAGE_ACCOUNT.'
Assert-True ($health.network_mode -eq 'none') `
    'Backup health monitoring must have no network.'
Assert-True ([bool]$health.read_only) `
    'Backup health monitoring must use a read-only root filesystem.'
Assert-True ($null -eq $health.ports) `
    'Backup health monitoring must not publish ports.'

$promtail = $compose.configs.promtail_config.content
Assert-True ($promtail.Contains('minecraft_backup_result')) `
    'Promtail must parse backup result signals.'
Assert-True ($promtail.Contains('minecraft_backup_health')) `
    'Promtail must parse backup freshness signals.'

Write-Host 'Azure backup Bicep, Compose, and alert policy tests passed.'
