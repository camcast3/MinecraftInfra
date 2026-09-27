#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$sourceCompose = Join-Path $repositoryRoot 'docker/palworld/docker-compose.yml'

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $output = @(& $Command @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code ${LASTEXITCODE}: $($output -join [Environment]::NewLine)"
    }
    return $output -join [Environment]::NewLine
}

$savedEnvironment = @{
    TS_AUTHKEY              = $env:TS_AUTHKEY
    PALWORLD_ADMIN_PASSWORD = $env:PALWORLD_ADMIN_PASSWORD
    PALWORLD_LAN_IP         = $env:PALWORLD_LAN_IP
    PALWORLD_PUID           = $env:PALWORLD_PUID
    PALWORLD_PGID           = $env:PALWORLD_PGID
    PALWORLD_DASHBOARD_PASSWORD = $env:PALWORLD_DASHBOARD_PASSWORD
}

try {
    $env:TS_AUTHKEY = 'tskey-auth-test-placeholder'
    $env:PALWORLD_ADMIN_PASSWORD = 'PalworldStartupTest-1234'
    $env:PALWORLD_LAN_IP = '192.0.2.10'
    $env:PALWORLD_PUID = '1000'
    $env:PALWORLD_PGID = '1000'
    $env:PALWORLD_DASHBOARD_PASSWORD = 'DashboardStartupTest-1234'

    $model = Invoke-Native -Command 'docker' -Arguments @(
        'compose', '--file', $sourceCompose, 'config', '--format', 'json'
    )
    $config = $model | ConvertFrom-Json
    $game = $config.services.palworld
    $dashboard = $config.services.dashboard
    $tailscale = $config.services.tailscale

    if ($config.services.PSObject.Properties.Name -contains 'palworld-init') {
        throw 'The upstream image must not retain the retired init service.'
    }
    if ($game.image -ne
        'thijsvanloef/palworld-server-docker:v2.7.3@sha256:be3ad49e373045a7b60478fd8b7f7411c1e293713dfa4733e563e798f276d688') {
        throw 'Palworld must use the reviewed, digest-pinned upstream image.'
    }
    if ($game.network_mode -ne 'service:tailscale') {
        throw 'Palworld must remain in the Tailscale network namespace.'
    }
    if ($game.environment.ADMIN_PASSWORD -ne $env:PALWORLD_ADMIN_PASSWORD -or
        $game.environment.REST_API_ENABLED -ne 'true' -or
        $game.environment.RCON_ENABLED -ne 'false' -or
        $game.environment.BACKUP_ENABLED -ne 'false') {
        throw 'Palworld administration or backup environment settings regressed.'
    }
    if ($game.environment.PUID -ne '1000' -or $game.environment.PGID -ne '1000') {
        throw 'Palworld must use the configured persistent-data owner.'
    }
    if ($game.volumes[0].source -ne '/data/palworld/server' -or
        $game.volumes[0].target -ne '/palworld') {
        throw 'Palworld must use the persistent upstream image layout.'
    }
    $playerPort = @($tailscale.ports) |
        Where-Object { $_.target -eq 8211 -and $_.protocol -eq 'udp' }
    if ($playerPort.Count -ne 1 -or
        $playerPort[0].published -ne '8211' -or
        $playerPort[0].host_ip -ne '192.0.2.10') {
        throw 'Palworld UDP 8211 must bind only to PALWORLD_LAN_IP.'
    }
    $dashboardPort = @($tailscale.ports) |
        Where-Object { $_.target -eq 3000 -and $_.protocol -eq 'tcp' }
    if ($dashboardPort.Count -ne 1 -or
        $dashboardPort[0].published -ne '3000' -or
        $dashboardPort[0].host_ip -ne '127.0.0.1') {
        throw 'The dashboard must publish only on VM loopback.'
    }
    if ($dashboard.network_mode -ne 'service:tailscale' -or
        $dashboard.environment.PALWORLD_REST_URL -ne
        'http://127.0.0.1:8212' -or
        $dashboard.environment.PUBLIC_VIEW_ENABLED -ne 'false') {
        throw 'The dashboard network or privacy boundary regressed.'
    }
    if ($dashboard.image -ne
        'ghcr.io/rnz01/palworld-server-dashboard:0.1.3@sha256:826d5aeaf5e2f13ae35e4353deb88d4319e69d7bdec7d5688bd27d76474d20d5') {
        throw 'The dashboard must use the reviewed, digest-pinned release.'
    }

    $imageCheck = Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm', '--security-opt', 'no-new-privileges:true',
        '--entrypoint', '/bin/bash', $game.image,
        '-ceu',
        'test -x /home/steam/server/init.sh; test -x /usr/local/bin/rest-cli; test "$(gosu steam id -u)" != 0'
    )
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$name" -Value $savedEnvironment[$name]
        }
    }
}

Write-Host 'Palworld upstream image and production Compose contract passed.'
