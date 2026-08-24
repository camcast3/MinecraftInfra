[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$azureComposePath = Join-Path $repositoryRoot 'platform/azure/edge/docker-compose.yml'
$testRoot = Join-Path $repositoryRoot 'build/multigame-rollout/edge-forwarding'
$project = 'minecraftinfra-rollout-forwarding'
$image = 'alpine/socat:1.8.1.3@sha256:3d9e7966201dd3a065df591020a09fd3c70845de7e7086e3531ea69db774406b'

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    $output = @(& $Command @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$Command failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output -join [Environment]::NewLine
    }
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )
    $allArguments = @(
        'compose', '--project-name', $project,
        '--file', (Join-Path $testRoot 'docker-compose.json')
    ) + $Arguments
    return Invoke-Native -Command 'docker' -Arguments $allArguments `
        -AllowFailure:$AllowFailure
}

function Get-PublishedPort {
    param(
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][int] $TargetPort,
        [Parameter(Mandatory)][ValidateSet('tcp', 'udp')][string] $Protocol
    )

    $container = (Invoke-Compose -Arguments @('ps', '--quiet', $Service)).Output.Trim()
    $ports = Invoke-Native -Command 'docker' -Arguments @(
        'inspect', '--format', '{{json .NetworkSettings.Ports}}', $container
    )
    $map = $ports.Output | ConvertFrom-Json
    $binding = @($map.PSObject.Properties["$TargetPort/$Protocol"].Value)[0]
    return [int]$binding.HostPort
}

if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$productionConfig = (
    Invoke-Native -Command 'docker' -Arguments @(
        'compose', '--file', $azureComposePath, 'config', '--format', 'json'
    )
).Output | ConvertFrom-Json

$forwardScript = ([string]$productionConfig.configs.edge_forward.content).Replace('$$', '$')
$healthScript = (
    [string]$productionConfig.configs.edge_forward_healthcheck.content
).Replace('$$', '$')
if ([string]::IsNullOrWhiteSpace($forwardScript) -or
    [string]::IsNullOrWhiteSpace($healthScript)) {
    throw 'Could not extract the production edge forwarder scripts from Compose.'
}

[System.IO.File]::WriteAllText(
    (Join-Path $testRoot 'forward.sh'),
    ($forwardScript -replace "`r`n", "`n"),
    [System.Text.UTF8Encoding]::new($false)
)
[System.IO.File]::WriteAllText(
    (Join-Path $testRoot 'healthcheck.sh'),
    ($healthScript -replace "`r`n", "`n"),
    [System.Text.UTF8Encoding]::new($false)
)
[System.IO.File]::WriteAllText(
    (Join-Path $testRoot 'backend-ip'),
    "100.127.255.10`n",
    [System.Text.UTF8Encoding]::new($false)
)
[System.IO.File]::WriteAllText(
    (Join-Path $testRoot 'bad-backend-ip'),
    "192.0.2.10`n",
    [System.Text.UTF8Encoding]::new($false)
)

$forwarderBase = [ordered]@{
    image      = $image
    entrypoint = @('/bin/sh', '/opt/edge/forward.sh')
    read_only  = $true
    cap_drop   = @('ALL')
    configs    = @(
        [ordered]@{ source = 'edge_forward'; target = '/opt/edge/forward.sh'; mode = 365 },
        [ordered]@{ source = 'edge_health'; target = '/opt/edge/healthcheck.sh'; mode = 365 }
    )
    networks   = @('rollout')
    healthcheck = [ordered]@{
        test         = @('CMD', '/bin/sh', '/opt/edge/healthcheck.sh')
        interval     = '1s'
        timeout      = '1s'
        retries      = 10
        start_period = '1s'
    }
}

function New-ForwarderService {
    param(
        [Parameter(Mandatory)][ValidateSet('tcp', 'udp')][string] $Protocol,
        [Parameter(Mandatory)][int] $ListenPort,
        [Parameter(Mandatory)][int] $BackendPort,
        [Parameter(Mandatory)][string] $SecretName,
        [switch] $Negative
    )

    $service = [ordered]@{}
    foreach ($entry in $forwarderBase.GetEnumerator()) {
        $service[$entry.Key] = $entry.Value
    }
    $service.environment = [ordered]@{
        FORWARD_PROTOCOL     = $Protocol
        FORWARD_LISTEN_PORT  = [string]$ListenPort
        FORWARD_BACKEND_PORT = [string]$BackendPort
        FORWARD_BACKEND_FILE = "/run/secrets/$SecretName"
    }
    $service.secrets = @($SecretName)
    if ($Negative) {
        $service.profiles = @('negative')
    } else {
        $service.ports = @([ordered]@{
            target    = $ListenPort
            published = 0
            protocol  = $Protocol
            host_ip   = '127.0.0.1'
        })
    }
    return $service
}

$fixture = [ordered]@{
    services = [ordered]@{
        backend = [ordered]@{
            image      = $image
            entrypoint = @('/bin/sh', '-c')
            command    = @(
                "socat TCP4-LISTEN:19001,reuseaddr,fork EXEC:/bin/cat & " +
                "socat UDP4-RECVFROM:19002,reuseaddr,fork EXEC:/bin/cat & wait"
            )
            networks   = [ordered]@{
                rollout = [ordered]@{ ipv4_address = '100.127.255.10' }
            }
        }
        'forward-tcp' = $(New-ForwarderService `
            -Protocol tcp -ListenPort 18001 -BackendPort 19001 `
            -SecretName backend_ip)
        'forward-udp' = $(New-ForwarderService `
            -Protocol udp -ListenPort 18002 -BackendPort 19002 `
            -SecretName backend_ip)
        'bad-route' = $(New-ForwarderService `
            -Protocol udp -ListenPort 18003 -BackendPort 19002 `
            -SecretName bad_backend_ip -Negative)
    }
    configs = [ordered]@{
        edge_forward = [ordered]@{ file = (Join-Path $testRoot 'forward.sh') }
        edge_health  = [ordered]@{ file = (Join-Path $testRoot 'healthcheck.sh') }
    }
    secrets = [ordered]@{
        backend_ip     = [ordered]@{ file = (Join-Path $testRoot 'backend-ip') }
        bad_backend_ip = [ordered]@{ file = (Join-Path $testRoot 'bad-backend-ip') }
    }
    networks = [ordered]@{
        rollout = [ordered]@{
            ipam = [ordered]@{
                config = @([ordered]@{ subnet = '100.127.255.0/24' })
            }
        }
    }
}

[System.IO.File]::WriteAllText(
    (Join-Path $testRoot 'docker-compose.json'),
    (($fixture | ConvertTo-Json -Depth 20) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

try {
    Invoke-Compose -Arguments @('up', '--detach', '--wait', '--wait-timeout', '60') | Out-Null
    $tcpPort = Get-PublishedPort -Service 'forward-tcp' -TargetPort 18001 -Protocol tcp
    $udpPort = Get-PublishedPort -Service 'forward-udp' -TargetPort 18002 -Protocol udp

    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    try {
        $tcpClient.Connect('127.0.0.1', $tcpPort)
        $stream = $tcpClient.GetStream()
        $stream.ReadTimeout = 5000
        $payload = [System.Text.Encoding]::UTF8.GetBytes("palworld-udp-is-separate`n")
        $stream.Write($payload, 0, $payload.Length)
        $buffer = [byte[]]::new(128)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $response = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        if ($response -ne "palworld-udp-is-separate`n") {
            throw 'TCP forwarding response did not match the Windrose smoke payload.'
        }
    } finally {
        $tcpClient.Dispose()
    }

    $udpClient = [System.Net.Sockets.UdpClient]::new()
    try {
        $udpClient.Client.ReceiveTimeout = 5000
        $udpClient.Connect('127.0.0.1', $udpPort)
        $payload = [System.Text.Encoding]::UTF8.GetBytes('palworld-udp-smoke')
        $null = $udpClient.Send($payload, $payload.Length)
        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $responseBytes = $udpClient.Receive([ref]$remote)
        $response = [System.Text.Encoding]::UTF8.GetString($responseBytes)
        if ($response -ne 'palworld-udp-smoke') {
            throw 'UDP forwarding response did not match the Palworld smoke payload.'
        }
    } finally {
        $udpClient.Dispose()
    }

    $negative = Invoke-Compose -Arguments @(
        '--profile', 'negative', 'run', '--rm', '--no-deps', 'bad-route'
    ) -AllowFailure
    if ($negative.ExitCode -eq 0 -or
        -not $negative.Output.Contains('Backend route must be a Tailscale IPv4 address')) {
        throw 'The production edge forwarder accepted a non-Tailscale backend route.'
    }
} catch {
    $logs = Invoke-Compose -Arguments @('logs', '--no-color') -AllowFailure
    Write-Host $logs.Output
    throw
} finally {
    Invoke-Compose -Arguments @('down', '--volumes', '--remove-orphans') -AllowFailure | Out-Null
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Production TCP/UDP forwarder smoke tests and negative route checks passed.'
