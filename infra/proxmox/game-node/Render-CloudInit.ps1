[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProfilePath,

    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

function Assert-Cidr {
    param([Parameter(Mandatory)][string] $Value)

    $parts = $Value.Split('/', 2)
    if ($parts.Count -ne 2) {
        throw "Management source '$Value' must use CIDR notation."
    }

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref] $address)) {
        throw "Management source '$Value' has an invalid IP address."
    }

    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref] $prefix)) {
        throw "Management source '$Value' has an invalid prefix."
    }

    $maximumPrefix = if (
        $address.AddressFamily -eq
        [System.Net.Sockets.AddressFamily]::InterNetwork
    ) { 32 } else { 128 }

    if ($prefix -lt 0 -or $prefix -gt $maximumPrefix) {
        throw "Management source '$Value' has an invalid prefix."
    }
}

$templatePath = Join-Path $PSScriptRoot 'cloud-init.yaml.tmpl'
if (-not [System.IO.Path]::IsPathRooted($ProfilePath)) {
    $ProfilePath = Join-Path (Get-Location) $ProfilePath
}
$ProfilePath = [System.IO.Path]::GetFullPath($ProfilePath)
$configuration = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json

if ($configuration.gameSlug -notmatch '^[a-z][a-z0-9-]*$') {
    throw "gameSlug must contain only lowercase letters, digits, and hyphens."
}
if ($configuration.serviceUser -notmatch '^[a-z_][a-z0-9_-]*$') {
    throw "serviceUser is not a valid Debian user name."
}
if ($configuration.tailscaleHostname -notmatch '^[a-z0-9][a-z0-9-]*$') {
    throw "tailscaleHostname is invalid."
}
if ($configuration.dataRoot -notmatch '^/data/[a-z][a-z0-9-]*$') {
    throw "dataRoot must be a direct child of /data."
}
if ($configuration.azureBackupContainer -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$') {
    throw "azureBackupContainer must be a valid Azure Blob container name."
}
if ($configuration.containerName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') {
    throw "containerName is invalid."
}
if (-not $configuration.backupSources -or $configuration.backupSources.Count -eq 0) {
    throw "At least one backup source is required."
}
foreach ($source in $configuration.backupSources) {
    if ($source -notmatch '^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$' -or
        $source -split '/' -contains '..') {
        throw "Backup source '$source' must be a safe relative path."
    }
}
if ($configuration.backupConsistency -notmatch '^[a-z0-9][a-z0-9._-]*$') {
    throw "backupConsistency is invalid."
}
$backupStopMode = if ($configuration.PSObject.Properties['backupStopMode']) {
    [string] $configuration.backupStopMode
} else {
    'container-stop'
}
if ($backupStopMode -notin @('container-stop', 'hook')) {
    throw "backupStopMode must be container-stop or hook."
}
if ([int] $configuration.sshPort -lt 1 -or [int] $configuration.sshPort -gt 65535) {
    throw "sshPort must be between 1 and 65535."
}
if ($configuration.rebootTime -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') {
    throw "rebootTime must use 24-hour HH:mm format."
}
if (-not $configuration.managementCidrs -or $configuration.managementCidrs.Count -eq 0) {
    throw "At least one management CIDR is required."
}

$managementRules = foreach ($source in $configuration.managementCidrs) {
    Assert-Cidr -Value $source
    "  - ufw allow from $source to any port $($configuration.sshPort) proto tcp comment 'OpenSSH management'"
}

$publicPortKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$publicPortsProperty = $configuration.PSObject.Properties['publicPorts']
$publicPorts = if ($null -eq $publicPortsProperty) {
    @()
} else {
    @($publicPortsProperty.Value)
}
$publicRules = foreach ($publicPort in $publicPorts) {
    $port = [int] $publicPort.port
    $protocol = [string] $publicPort.protocol
    $comment = [string] $publicPort.comment

    if ($port -lt 1 -or $port -gt 65535) {
        throw "Public port must be between 1 and 65535."
    }
    if ($protocol -notin @('tcp', 'udp')) {
        throw "Public port protocol must be tcp or udp."
    }
    if ($comment -notmatch '^[A-Za-z0-9 ._-]+$') {
        throw "Public port comment contains unsupported characters."
    }
    if (-not $publicPortKeys.Add("${port}/${protocol}")) {
        throw "Duplicate public port '${port}/${protocol}'."
    }

    "  - ufw allow $port/$protocol comment '$comment'"
}

function ConvertTo-CloudInitBlock {
    param([Parameter(Mandatory)][string] $Content)

    return (($Content -replace "`r`n", "`n").TrimEnd("`n") -split "`n" |
        ForEach-Object {
            if ($_ -eq '') { '' } else { "      $_" }
        }) -join "`n"
}

$backupAssetRoot = Join-Path $PSScriptRoot 'backup'
$backupAssets = [ordered] @{
    '@@BACKUP_SCRIPT@@' = 'game-backup.sh'
    '@@BACKUP_HEALTH_SCRIPT@@' = 'game-backup-health.sh'
    '@@BACKUP_RECOVER_SCRIPT@@' = 'game-backup-recover.sh'
    '@@RESTORE_SCRIPT@@' = 'game-restore.sh'
    '@@BACKUP_SERVICE@@' = 'game-backup@.service'
    '@@BACKUP_TIMER@@' = 'game-backup@.timer'
    '@@BACKUP_HEALTH_SERVICE@@' = 'game-backup-health@.service'
    '@@BACKUP_HEALTH_TIMER@@' = 'game-backup-health@.timer'
    '@@BACKUP_RECOVER_SERVICE@@' = 'game-backup-recover@.service'
    '@@RCLONE_EXAMPLE@@' = 'rclone.conf.example'
}

$tokens = [ordered] @{
    '@@DISPLAY_NAME@@' = [string] $configuration.displayName
    '@@GAME_SLUG@@' = [string] $configuration.gameSlug
    '@@SERVICE_USER@@' = [string] $configuration.serviceUser
    '@@TAILSCALE_HOSTNAME@@' = [string] $configuration.tailscaleHostname
    '@@DATA_ROOT@@' = [string] $configuration.dataRoot
    '@@SSH_PORT@@' = [string] $configuration.sshPort
    '@@REBOOT_TIME@@' = [string] $configuration.rebootTime
    '@@AZURE_BACKUP_CONTAINER@@' = [string] $configuration.azureBackupContainer
    '@@CONTAINER_NAME@@' = [string] $configuration.containerName
    '@@BACKUP_SOURCES@@' = @($configuration.backupSources) -join ':'
    '@@BACKUP_CONSISTENCY@@' = [string] $configuration.backupConsistency
    '@@BACKUP_STOP_MODE@@' = $backupStopMode
    '@@MANAGEMENT_UFW_RULES@@' = $managementRules -join "`n"
    '@@PUBLIC_UFW_RULES@@' = $publicRules -join "`n"
}
foreach ($asset in $backupAssets.GetEnumerator()) {
    $assetPath = Join-Path $backupAssetRoot $asset.Value
    $tokens[$asset.Key] = ConvertTo-CloudInitBlock (
        Get-Content -LiteralPath $assetPath -Raw -Encoding UTF8
    )
}

$rendered = Get-Content -LiteralPath $templatePath -Raw
foreach ($token in $tokens.GetEnumerator()) {
    $rendered = $rendered.Replace($token.Key, $token.Value)
}

if ($rendered -match '@@[A-Z0-9_]+@@') {
    throw "The rendered cloud-init contains an unresolved token: $($Matches[0])"
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Get-Location) "$($configuration.gameSlug)-cloud-init.yaml"
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) $OutputPath
}

$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$normalized = $rendered -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($OutputPath, $normalized, $utf8NoBom)

Write-Output $OutputPath
