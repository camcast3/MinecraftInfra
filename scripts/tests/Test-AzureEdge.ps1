[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$composePath = Join-Path $repositoryRoot 'docker/azure/docker-compose.yml'
$networkBicepPath = Join-Path $repositoryRoot 'infra/azure/modules/network.bicep'
$mainBicepPath = Join-Path $repositoryRoot 'infra/azure/main.bicep'
$passed = 0

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
    $script:passed++
}

function Assert-SetEquals {
    param(
        [string[]] $Actual,
        [string[]] $Expected,
        [string] $Message
    )

    $difference = @(
        Compare-Object `
            -ReferenceObject @($Expected | Sort-Object -Unique) `
            -DifferenceObject @($Actual | Sort-Object -Unique)
    )
    if ($difference.Count -gt 0) {
        $actualText = (@($Actual | Sort-Object -Unique) -join ', ')
        $expectedText = (@($Expected | Sort-Object -Unique) -join ', ')
        throw "$Message Expected [$expectedText], got [$actualText]."
    }
    $script:passed++
}

function Invoke-NativeText {
    param(
        [string] $Command,
        [string[]] $Arguments
    )

    $previousPythonUtf8 = $env:PYTHONUTF8
    $env:PYTHONUTF8 = '1'
    try {
        $output = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:PYTHONUTF8 = $previousPythonUtf8
    }
    if ($exitCode -ne 0) {
        throw "$Command failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }
    return $output -join [Environment]::NewLine
}

$composeJson = Invoke-NativeText -Command 'docker' -Arguments @(
    'compose',
    '-f', $composePath,
    'config',
    '--format', 'json'
) | ConvertFrom-Json

$publishedPorts = @(
    foreach ($serviceProperty in $composeJson.services.PSObject.Properties) {
        $portsProperty = $serviceProperty.Value.PSObject.Properties['ports']
        if ($null -eq $portsProperty) {
            continue
        }
        foreach ($port in @($portsProperty.Value)) {
            "$($port.published):$($port.target)/$($port.protocol)"
        }
    }
)
$expectedPublishedPorts = @(
    '25565:25577/tcp',
    '8211:8211/udp',
    '7777:7777/tcp',
    '7777:7777/udp'
)
Assert-SetEquals `
    -Actual $publishedPorts `
    -Expected $expectedPublishedPorts `
    -Message 'Azure Compose published-port surface differs.'

$servicesWithPublishedPorts = @(
    foreach ($serviceProperty in $composeJson.services.PSObject.Properties) {
        if ($null -ne $serviceProperty.Value.PSObject.Properties['ports']) {
            $serviceProperty.Name
        }
    }
)
Assert-SetEquals `
    -Actual $servicesWithPublishedPorts `
    -Expected @('tailscale') `
    -Message 'Only the shared Tailscale namespace may publish host ports.'

$savedEnvironment = @{
    TS_AUTHKEY = $env:TS_AUTHKEY
    PALWORLD_ADMIN_PASSWORD = $env:PALWORLD_ADMIN_PASSWORD
    WINDROSE_TS_AUTHKEY = $env:WINDROSE_TS_AUTHKEY
    WINDROSE_SERVER_DESCRIPTION_JSON = $env:WINDROSE_SERVER_DESCRIPTION_JSON
}
try {
    $env:TS_AUTHKEY = 'test-route-key'
    $env:PALWORLD_ADMIN_PASSWORD = 'TestPassword1234567890.Safe'
    $env:WINDROSE_TS_AUTHKEY = 'test-route-key'
    $env:WINDROSE_SERVER_DESCRIPTION_JSON = '{}'

    foreach ($backendCompose in @(
        'docker/palworld/docker-compose.yml',
        'docker/windrose/docker-compose.yml'
    )) {
        $backendConfig = Invoke-NativeText -Command 'docker' -Arguments @(
            'compose',
            '-f', (Join-Path $repositoryRoot $backendCompose),
            'config',
            '--format', 'json'
        ) | ConvertFrom-Json
        $backendPublishedPorts = @(
            foreach ($serviceProperty in $backendConfig.services.PSObject.Properties) {
                $portsProperty = $serviceProperty.Value.PSObject.Properties['ports']
                if ($null -ne $portsProperty) {
                    @($portsProperty.Value)
                }
            }
        )
        Assert-True `
            ($backendPublishedPorts.Count -eq 0) `
            "$backendCompose must not publish a host port; the Azure edge owns player ingress."
    }
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$name" -Value $savedEnvironment[$name]
        }
    }
}

$forbiddenPublicPorts = @(22, 8212, 25575, 8080, 8081, 9080, 9100, 9985, 12345)
foreach ($forbiddenPort in $forbiddenPublicPorts) {
    Assert-True `
        -Condition (-not ($publishedPorts -match "^${forbiddenPort}:")) `
        -Message "Forbidden admin or metrics port $forbiddenPort is publicly published."
}

$forwarders = [ordered]@{
    'palworld-forwarder' = @{
        Protocol = 'udp'
        ListenPort = '8211'
        BackendPort = '8211'
        Secret = 'palworld_tailnet_ip'
    }
    'windrose-tcp-forwarder' = @{
        Protocol = 'tcp'
        ListenPort = '7777'
        BackendPort = '7777'
        Secret = 'windrose_tailnet_ip'
    }
    'windrose-udp-forwarder' = @{
        Protocol = 'udp'
        ListenPort = '7777'
        BackendPort = '7777'
        Secret = 'windrose_tailnet_ip'
    }
}

foreach ($entry in $forwarders.GetEnumerator()) {
    $serviceProperty = $composeJson.services.PSObject.Properties[$entry.Key]
    Assert-True ($null -ne $serviceProperty) "Missing forwarder service '$($entry.Key)'."
    $service = $serviceProperty.Value
    $expected = $entry.Value

    Assert-True `
        ($service.network_mode -eq 'service:tailscale') `
        "$($entry.Key) must share the Tailscale network namespace."
    Assert-True `
        ($service.image -match '^[^@\s:]+(?:/[^@\s:]+)*:[^@\s]+@sha256:[0-9a-f]{64}$') `
        "$($entry.Key) image must be pinned to a tag and digest."
    Assert-True `
        ($service.environment.FORWARD_PROTOCOL -eq $expected.Protocol) `
        "$($entry.Key) protocol mapping is incorrect."
    Assert-True `
        ([string] $service.environment.FORWARD_LISTEN_PORT -eq $expected.ListenPort) `
        "$($entry.Key) listen port is incorrect."
    Assert-True `
        ([string] $service.environment.FORWARD_BACKEND_PORT -eq $expected.BackendPort) `
        "$($entry.Key) backend port is incorrect."
    Assert-True `
        ($service.secrets.source -contains $expected.Secret) `
        "$($entry.Key) must consume its Key Vault-backed route file."
    Assert-True `
        ($null -ne $service.healthcheck) `
        "$($entry.Key) must define a health check."
}

$contractRoutes = @()
foreach ($contractName in @('palworld.json', 'windrose.json')) {
    $contractPath = Join-Path $repositoryRoot "contracts/games/$contractName"
    $contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    foreach ($route in @($contract.edgeRoutes)) {
        $contractRoutes += "$($route.publicPort):$($route.backendPort)/$($route.protocol)"
    }
}
Assert-SetEquals `
    -Actual $contractRoutes `
    -Expected @('8211:8211/udp', '7777:7777/tcp', '7777:7777/udp') `
    -Message 'Game edge-route contracts do not match Azure forwarding.'

$firewallPath = Join-Path $repositoryRoot 'docker/azure/reconcile-firewall.sh'
$firewallText = Get-Content -LiteralPath $firewallPath -Raw -Encoding UTF8
$firewallRules = @(
    [regex]::Matches(
        $firewallText,
        '(?m)^ufw allow (?<port>[0-9]+)/(?:proto )?(?<protocol>tcp|udp)\b'
    ) | ForEach-Object {
        "$($_.Groups['port'].Value)/$($_.Groups['protocol'].Value)"
    }
)
Assert-SetEquals `
    -Actual $firewallRules `
    -Expected @('25565/tcp', '8211/udp', '7777/tcp', '7777/udp') `
    -Message 'Live UFW reconciliation differs from the Compose public surface.'
Assert-True `
    ($firewallText.Contains('ufw --force reset')) `
    'UFW reconciliation must remove stale public rules before adding the desired set.'

foreach ($backendBootstrap in @(
    'infra/proxmox/game-node/generated/palworld-cloud-init.yaml',
    'infra/proxmox/game-node/generated/windrose-cloud-init.yaml'
)) {
    $backendBootstrapText = Get-Content `
        -LiteralPath (Join-Path $repositoryRoot $backendBootstrap) `
        -Raw -Encoding UTF8
    Assert-True `
        (-not ($backendBootstrapText -match 'ufw allow (?:8211/udp|7777/(?:tcp|udp))')) `
        "$backendBootstrap must not open a public player port."
}

$networkArm = Invoke-NativeText -Command 'az' -Arguments @(
    'bicep', 'build',
    '--file', $networkBicepPath,
    '--stdout',
    '--only-show-errors'
) | ConvertFrom-Json
$nsg = @($networkArm.resources | Where-Object {
    $_.type -eq 'Microsoft.Network/networkSecurityGroups'
})
Assert-True ($nsg.Count -eq 1) 'Expected exactly one NSG in network.bicep.'

$nsgAllows = @(
    foreach ($rule in @($nsg[0].properties.securityRules)) {
        if ($rule.properties.direction -eq 'Inbound' -and
            $rule.properties.access -eq 'Allow') {
            "$($rule.properties.destinationPortRange)/$($rule.properties.protocol.ToLowerInvariant())"
        }
    }
)
Assert-SetEquals `
    -Actual $nsgAllows `
    -Expected @('25565/tcp', '8211/udp', '7777/tcp', '7777/udp') `
    -Message 'Azure NSG allows differ from the intended player surface.'

$null = Invoke-NativeText -Command 'az' -Arguments @(
    'bicep', 'build',
    '--file', $mainBicepPath,
    '--only-show-errors'
)

$vmBicepText = Get-Content `
    -LiteralPath (Join-Path $repositoryRoot 'infra/azure/modules/vm.bicep') `
    -Raw -Encoding UTF8
Assert-True `
    ($vmBicepText.Contains('bash /opt/minecraft/docker/azure/reconcile-firewall.sh')) `
    'Fresh VM bootstrap must call the shared firewall reconciler.'

$workflowText = Get-Content `
    -LiteralPath (Join-Path $repositoryRoot '.github/workflows/deploy-azure.yml') `
    -Raw -Encoding UTF8
Assert-True `
    ($workflowText.Contains('bash docker/azure/reconcile-firewall.sh')) `
    'Live Azure deployment must call the shared firewall reconciler.'
Assert-True `
    ($workflowText.Contains('--wait --wait-timeout 180')) `
    'Azure deployment must wait for Compose health checks.'

$refreshText = Get-Content `
    -LiteralPath (Join-Path $repositoryRoot 'docker/azure/refresh-env.sh') `
    -Raw -Encoding UTF8
Assert-True `
    ($refreshText.Contains('kv_secret_optional "palworld-tailscale-ip"')) `
    'Palworld routing must be optional until the planned backend is promoted.'
Assert-True `
    ($refreshText.Contains('kv_secret_optional "windrose-tailscale-ip"')) `
    'Windrose routing must be optional until the planned backend is promoted.'
Assert-True `
    ($refreshText.Contains("printf '%s' '100.64.0.0'")) `
    'Unconfigured planned routes must use the non-routable Tailscale sink.'

Write-Host "All $passed Azure edge assertions passed."
