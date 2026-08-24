[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures/rollout'
$composePath = Join-Path $fixtureRoot 'docker-compose.yml'
$project = 'minecraftinfra-rollout-lifecycle'
$imageV1 = 'minecraftinfra-rollout-fixture:v1'
$imageV2 = 'minecraftinfra-rollout-fixture:v2'

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
        'compose', '--project-name', $project, '--file', $composePath
    ) + $Arguments
    return Invoke-Native -Command 'docker' -Arguments $allArguments `
        -AllowFailure:$AllowFailure
}

function Get-ContainerId {
    $result = Invoke-Compose -Arguments @('ps', '--quiet', 'game')
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        throw 'Lifecycle fixture container was not created.'
    }
    return $result.Output.Trim()
}

function Wait-ForState {
    param(
        [Parameter(Mandatory)][string] $ContainerId,
        [Parameter(Mandatory)][string] $ExpectedHealth,
        [int] $TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $health = (Invoke-Native -Command 'docker' -Arguments @(
            'inspect', '--format',
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}',
            $ContainerId
        )).Output.Trim()
        if ($health -eq $ExpectedHealth) {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Container $ContainerId did not reach health state '$ExpectedHealth'."
}

$savedEnvironment = @{
    FIXTURE_IMAGE   = $env:FIXTURE_IMAGE
    FIXTURE_RELEASE = $env:FIXTURE_RELEASE
    FAIL_HEALTH     = $env:FAIL_HEALTH
}

try {
    Invoke-Compose -Arguments @('down', '--volumes', '--remove-orphans') -AllowFailure | Out-Null

    foreach ($release in @('v1', 'v2')) {
        Invoke-Native -Command 'docker' -Arguments @(
            'build',
            '--file', (Join-Path $fixtureRoot 'Dockerfile'),
            '--build-arg', "RELEASE=$release",
            '--tag', "minecraftinfra-rollout-fixture:$release",
            $fixtureRoot
        ) | Out-Null
    }

    $env:FIXTURE_IMAGE = $imageV1
    $env:FIXTURE_RELEASE = 'v1'
    $env:FAIL_HEALTH = 'false'
    Invoke-Compose -Arguments @('up', '--detach') | Out-Null
    $container = Get-ContainerId
    Invoke-Native -Command 'docker' -Arguments @(
        'exec', $container, 'sh', '-c', "printf 'fixture-save-v1\n' > /state/durable-save"
    ) | Out-Null
    Wait-ForState -ContainerId $container -ExpectedHealth 'healthy'

    $env:FIXTURE_IMAGE = $imageV2
    $env:FIXTURE_RELEASE = 'v2'
    Invoke-Compose -Arguments @('up', '--detach', '--force-recreate') | Out-Null
    $container = Get-ContainerId
    Wait-ForState -ContainerId $container -ExpectedHealth 'healthy'
    $release = (Invoke-Native -Command 'docker' -Arguments @(
        'exec', $container, 'cat', '/state/current-release'
    )).Output.Trim()
    $save = (Invoke-Native -Command 'docker' -Arguments @(
        'exec', $container, 'cat', '/state/durable-save'
    )).Output.Trim()
    if ($release -ne 'v2' -or $save -ne 'fixture-save-v1') {
        throw 'Compose recreation did not preserve the fixture save while changing releases.'
    }

    $restartCount = [int](Invoke-Native -Command 'docker' -Arguments @(
        'inspect', '--format', '{{.RestartCount}}', $container
    )).Output.Trim()
    Invoke-Native -Command 'docker' -Arguments @(
        'exec', $container, 'touch', '/state/crash-once'
    ) | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $currentRestartCount = [int](Invoke-Native -Command 'docker' -Arguments @(
            'inspect', '--format', '{{.RestartCount}}', $container
        )).Output.Trim()
    } while ($currentRestartCount -le $restartCount -and [DateTime]::UtcNow -lt $deadline)
    if ($currentRestartCount -le $restartCount) {
        throw 'The unless-stopped restart policy did not recover the killed fixture.'
    }
    Wait-ForState -ContainerId $container -ExpectedHealth 'healthy'

    $env:FAIL_HEALTH = 'true'
    Invoke-Compose -Arguments @('up', '--detach', '--force-recreate') | Out-Null
    $container = Get-ContainerId
    Wait-ForState -ContainerId $container -ExpectedHealth 'unhealthy'

    $env:FIXTURE_IMAGE = $imageV1
    $env:FIXTURE_RELEASE = 'v1'
    $env:FAIL_HEALTH = 'false'
    Invoke-Compose -Arguments @('up', '--detach', '--force-recreate') | Out-Null
    $container = Get-ContainerId
    Wait-ForState -ContainerId $container -ExpectedHealth 'healthy'
    $release = (Invoke-Native -Command 'docker' -Arguments @(
        'exec', $container, 'cat', '/state/current-release'
    )).Output.Trim()
    $save = (Invoke-Native -Command 'docker' -Arguments @(
        'exec', $container, 'cat', '/state/durable-save'
    )).Output.Trim()
    if ($release -ne 'v1' -or $save -ne 'fixture-save-v1') {
        throw 'Image rollback did not restore v1 while preserving the fixture save.'
    }
} finally {
    Invoke-Compose -Arguments @('down', '--volumes', '--remove-orphans') -AllowFailure | Out-Null
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$name" -Value $savedEnvironment[$name]
        }
    }
}

Write-Host 'Compose recreate, restart-failure, persistence, update, and rollback simulations passed.'
