[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$validatorPath = Join-Path $repositoryRoot 'tools/validation/Validate-GameContracts.ps1'
$sourceContracts = Join-Path $repositoryRoot 'platform/contracts'
$testRoot = Join-Path $repositoryRoot 'build/game-contract-tests'
$caseRoot = Join-Path $testRoot 'contracts'
$fixtureRepository = Join-Path $testRoot 'repository'
$passed = 0

function Reset-Contracts {
    if (Test-Path -LiteralPath $caseRoot) {
        Remove-Item -LiteralPath $caseRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceContracts '*') -Destination $caseRoot -Recurse -Force
}

function Invoke-Validation {
    param(
        [string]$ValidationRepositoryRoot = $repositoryRoot
    )
    try {
        & $validatorPath `
            -RepositoryRoot $ValidationRepositoryRoot `
            -ContractsRoot $caseRoot *> $null
        return [pscustomobject]@{
            Succeeded = $true
            Message   = ''
        }
    } catch {
        return [pscustomobject]@{
            Succeeded = $false
            Message   = $_.Exception.Message
        }
    }
}

function Assert-Succeeds {
    param([string]$Name)
    $result = Invoke-Validation
    if (-not $result.Succeeded) {
        throw "Expected '$Name' to pass, but it failed: $($result.Message)"
    }
    $script:passed++
    Write-Host "PASS: $Name"
}

function Assert-Fails {
    param(
        [string]$Name,
        [string]$ExpectedMessage,
        [string]$ValidationRepositoryRoot = $repositoryRoot
    )
    $result = Invoke-Validation -ValidationRepositoryRoot $ValidationRepositoryRoot
    if ($result.Succeeded) {
        throw "Expected '$Name' to fail, but it passed."
    }
    if (-not $result.Message.Contains($ExpectedMessage)) {
        throw "Expected '$Name' to contain '$ExpectedMessage', got: $($result.Message)"
    }
    $script:passed++
    Write-Host "PASS: $Name"
}

function New-FixtureRepository {
    if (Test-Path -LiteralPath $fixtureRepository) {
        Remove-Item -LiteralPath $fixtureRepository -Recurse -Force
    }

    $relativeFiles = @(
        'platform/azure/edge/docker-compose.yml',
        'games/minecraft/c2e2/docker-compose.yml',
        'games/palworld/docker-compose.yml',
        'games/windrose/docker-compose.yml',
        'docker/azure/docker-compose.yml',
        'docker/proxmox/docker-compose.yml',
        'docker/palworld/docker-compose.yml',
        'docker/windrose/docker-compose.yml',
        'infra/azure/main.bicep',
        'infra/proxmox/cloud-init.yaml',
        'infra/proxmox/game-node/profiles/palworld.json',
        'infra/proxmox/game-node/profiles/windrose.json'
    )
    foreach ($relativeFile in $relativeFiles) {
        $source = Join-Path $repositoryRoot $relativeFile
        $destination = Join-Path $fixtureRepository $relativeFile
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Read-Json {
    param([string]$RelativePath)
    $path = Join-Path $caseRoot $RelativePath
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Json {
    param(
        [string]$RelativePath,
        [object]$Value
    )
    $path = Join-Path $caseRoot $RelativePath
    $json = (ConvertTo-Json -InputObject $Value -Depth 20) + "`n"
    [System.IO.File]::WriteAllText(
        $path,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

try {
    Reset-Contracts
    Assert-Succeeds -Name 'seed contracts'

    Reset-Contracts
    New-FixtureRepository
    $composePath = Join-Path $fixtureRepository 'platform/azure/edge/docker-compose.yml'
    $compose = Get-Content -LiteralPath $composePath -Raw -Encoding UTF8
    $compose = $compose.Replace(
        'tailscale/tailscale:v1.102.2@sha256:4107a12b1a0466bb3f2c968d5fa35acf509cd7865a958ce1af36724e9f016342',
        'tailscale/tailscale:latest'
    )
    [System.IO.File]::WriteAllText(
        $composePath,
        $compose,
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Fails `
        -Name 'unpinned production Compose image' `
        -ExpectedMessage "production image 'tailscale/tailscale:latest' is not pinned" `
        -ValidationRepositoryRoot $fixtureRepository

    Reset-Contracts
    $contract = Read-Json 'games/minecraft-velocity.json'
    $contract.image.reference = 'itzg/mc-proxy:latest'
    Write-Json 'games/minecraft-velocity.json' $contract
    Assert-Fails -Name 'unpinned production image' -ExpectedMessage 'production image must be pinned'

    Reset-Contracts
    $contract = Read-Json 'games/windrose.json'
    $contract.image.reference =
        'windroseserver/windroseserver:test@sha256:' + ('0' * 64)
    Write-Json 'games/windrose.json' $contract
    Assert-Fails `
        -Name 'planned deployment image mismatch' `
        -ExpectedMessage 'image reference does not match deploymentPath'

    Reset-Contracts
    $contract = Read-Json 'games/minecraft-velocity.json'
    $contract.ports += [pscustomobject]@{
        name        = 'duplicate'
        publicPort  = 25565
        privatePort = 25578
        protocol    = 'tcp'
        exposure    = 'public'
        audience    = 'players'
    }
    Write-Json 'games/minecraft-velocity.json' $contract
    Assert-Fails -Name 'duplicate public port' -ExpectedMessage 'Duplicate public port'

    Reset-Contracts
    $contract = Read-Json 'games/minecraft-velocity.json'
    $contract.ports += [pscustomobject]@{
        name        = 'public-rcon'
        publicPort  = 25575
        privatePort = 25575
        protocol    = 'tcp'
        exposure    = 'public'
        audience    = 'admin'
    }
    Write-Json 'games/minecraft-velocity.json' $contract
    Assert-Fails -Name 'public admin API' -ExpectedMessage 'publicly exposes admin'

    Reset-Contracts
    $contract = Read-Json 'games/palworld.json'
    $contract.edgeRoutes[0].backendPort = 8212
    Write-Json 'games/palworld.json' $contract
    Assert-Fails `
        -Name 'edge route to admin port' `
        -ExpectedMessage 'must target a declared tailnet player port'

    Reset-Contracts
    $contract = Read-Json 'games/windrose.json'
    $contract.edgeRoutes[1].protocol = 'tcp'
    Write-Json 'games/windrose.json' $contract
    Assert-Fails `
        -Name 'duplicate edge public route' `
        -ExpectedMessage 'Duplicate public port'

    Reset-Contracts
    $contract = Read-Json 'games/minecraft-c2e2.json'
    $contract.persistentPaths = @()
    Write-Json 'games/minecraft-c2e2.json' $contract
    Assert-Fails -Name 'missing persistence' -ExpectedMessage 'at least one persistent path'

    Reset-Contracts
    $contract = Read-Json 'games/minecraft-c2e2.json'
    $contract.PSObject.Properties.Remove('backupPolicy')
    Write-Json 'games/minecraft-c2e2.json' $contract
    Assert-Fails -Name 'missing backup policy' -ExpectedMessage 'missing ''backupPolicy'''

    Reset-Contracts
    $contract = Read-Json 'games/minecraft-c2e2.json'
    $contract.PSObject.Properties.Remove('updatePolicy')
    Write-Json 'games/minecraft-c2e2.json' $contract
    Assert-Fails -Name 'missing update policy' -ExpectedMessage 'missing ''updatePolicy'''

    Reset-Contracts
    New-FixtureRepository
    $composePath = Join-Path $fixtureRepository 'platform/azure/edge/docker-compose.yml'
    $compose = Get-Content -LiteralPath $composePath -Raw -Encoding UTF8
    $compose = $compose.Replace(
        'TS_AUTHKEY: file:/run/secrets/ts_authkey',
        'TS_AUTHKEY: tskey-auth-committed-value'
    )
    [System.IO.File]::WriteAllText(
        $composePath,
        $compose,
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Fails `
        -Name 'committed Compose secret value' `
        -ExpectedMessage "commits a value for secret setting 'TS_AUTHKEY'" `
        -ValidationRepositoryRoot $fixtureRepository

    Reset-Contracts
    $contract = Read-Json 'games/minecraft-c2e2.json'
    $contract | Add-Member -NotePropertyName secretValue -NotePropertyValue 'not-allowed'
    Write-Json 'games/minecraft-c2e2.json' $contract
    Assert-Fails -Name 'contract secret value' -ExpectedMessage 'forbidden secret-value property'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host "All $passed game contract validation tests passed."
