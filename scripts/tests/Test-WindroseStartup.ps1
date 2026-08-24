#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$sourceCompose = Join-Path $repositoryRoot 'docker/windrose/docker-compose.yml'
$testRoot = Join-Path $repositoryRoot "build/windrose-startup-tests-$PID"
$launchPath = Join-Path $testRoot 'launch.sh'
$termPath = Join-Path $testRoot 'term-target.sh'
$lifecycleCompose = Join-Path $testRoot 'docker-compose.yml'
$project = "minecraftinfra-windrose-lifecycle-$PID"
$containerName = "minecraftinfra-windrose-sigterm-$PID"
$configVolume = "$project-config"
$invalidVolume = "$project-invalid"

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    $output = @(& $Command @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
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
        '--file', $lifecycleCompose
    ) + $Arguments
    return Invoke-Native -Command 'docker' -Arguments $allArguments `
        -AllowFailure:$AllowFailure
}

function Wait-ForHealth {
    param(
        [Parameter(Mandatory)][string] $Expected,
        [int] $TimeoutSeconds = 30
    )

    $container = (Invoke-Compose -Arguments @('ps', '--quiet', 'game')).Output.Trim()
    if ([string]::IsNullOrWhiteSpace($container)) {
        throw 'Windrose lifecycle fixture container was not created.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $health = (Invoke-Native -Command 'docker' -Arguments @(
            'inspect', '--format',
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}',
            $container
        )).Output.Trim()
        if ($health -eq $Expected) {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Lifecycle fixture did not become $Expected."
}

$savedEnvironment = @{
    WINDROSE_TS_AUTHKEY                 = $env:WINDROSE_TS_AUTHKEY
    WINDROSE_SERVER_DESCRIPTION_JSON   = $env:WINDROSE_SERVER_DESCRIPTION_JSON
    WINDROSE_RESEED_SERVER_DESCRIPTION = $env:WINDROSE_RESEED_SERVER_DESCRIPTION
    FIXTURE_RELEASE                    = $env:FIXTURE_RELEASE
    FAIL_HEALTH                        = $env:FAIL_HEALTH
}

try {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    $validDescription = '{"UseDirectConnection":true,"DirectConnectionServerPort":7777,"PersistentServerId":"validation-a","WorldIslandId":"validation-a"}'
    $reseedDescription = '{"UseDirectConnection":true,"DirectConnectionServerPort":7777,"PersistentServerId":"validation-b","WorldIslandId":"validation-b"}'
    $invalidDescription = '{"UseDirectConnection":true,"DirectConnectionServerPort":7778}'
    $env:WINDROSE_TS_AUTHKEY = 'tskey-auth-validation-placeholder'
    $env:WINDROSE_SERVER_DESCRIPTION_JSON = $validDescription
    $env:WINDROSE_RESEED_SERVER_DESCRIPTION = 'false'

    $modelResult = Invoke-Native -Command 'docker' -Arguments @(
        'compose', '--file', $sourceCompose, 'config', '--format', 'json'
    )
    $model = $modelResult.Output | ConvertFrom-Json
    $game = $model.services.windrose
    $image = [string] $game.image

    if ($image -notmatch
        '^windroseserver/windroseserver:[^@\s]+@sha256:[0-9a-f]{64}$') {
        throw 'Windrose must use a tag-and-digest pinned official image.'
    }
    if ($game.network_mode -ne 'service:tailscale' -or
        $game.stop_signal -ne 'SIGTERM' -or
        $game.stop_grace_period -ne '2m0s' -or
        $game.entrypoint -join ' ' -ne '/bin/bash /opt/windrose/launch.sh') {
        throw 'Windrose network or graceful shutdown configuration regressed.'
    }
    if ($null -ne $game.PSObject.Properties['ports']) {
        throw 'Windrose must not publish a host port.'
    }
    $composeText = Get-Content -LiteralPath $sourceCompose -Raw -Encoding UTF8
    if ($composeText -match '(?m)^\s*(?:-\s*)?7778(?::|/|\s|$)') {
        throw 'Windrose must not configure unverified port 7778.'
    }
    foreach ($protocolFile in @('/proc/net/tcp', '/proc/net/udp')) {
        if (-not $model.configs.windrose_healthcheck.content.Contains($protocolFile)) {
            throw "Windrose health check is missing $protocolFile."
        }
    }

    Invoke-Native -Command 'docker' -Arguments @('pull', $image) | Out-Null
    $imageModel = (
        Invoke-Native -Command 'docker' -Arguments @('image', 'inspect', $image)
    ).Output | ConvertFrom-Json
    if ($imageModel[0].Architecture -ne 'amd64') {
        throw 'The pinned Windrose image must be amd64.'
    }
    $exposedPorts = @($imageModel[0].Config.ExposedPorts.PSObject.Properties.Name)
    if (Compare-Object $exposedPorts @('7777/tcp', '7777/udp')) {
        throw "Unexpected image ports: $($exposedPorts -join ', ')"
    }
    $nativeCheck = @(
        'binary=/home/ue_user/app/R5/Binaries/Linux/WindroseServer-Linux-Shipping'
        'test -x "$binary"'
        'test "$(od -An -tx1 -N4 "$binary" | tr -d " \n")" = 7f454c46'
        '! command -v wine'
        '! command -v wine64'
        'ldd "$binary" | grep -F "libsteam_api.so"'
    ) -join '; '
    Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm', '--entrypoint', '/bin/bash', $image, '-ceu', $nativeCheck
    ) | Out-Null

    $launch = [string] $model.configs.windrose_launch.content
    $launch = $launch.Replace('$$', '$').Replace(
        'exec ./R5/Binaries/Linux/WindroseServer-Linux-Shipping R5 -log',
        'exec "$@"'
    ).Replace("`r`n", "`n")
    if (-not $launch.Contains('exec "$@"') -or
        $launch.Contains('exec ./R5/Binaries/Linux/WindroseServer-Linux-Shipping')) {
        throw 'The safe test-only launcher substitution failed.'
    }
    [System.IO.File]::WriteAllText(
        $launchPath, $launch, [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $termPath,
        @'
#!/bin/bash
set -eu
trap 'printf "sigterm\n" > /config/sigterm-observed; exit 0' TERM
while :; do
  sleep 1 &
  wait $!
done
'@.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )

    foreach ($volume in @($configVolume, $invalidVolume)) {
        Invoke-Native -Command 'docker' -Arguments @('volume', 'create', $volume) |
            Out-Null
        Invoke-Native -Command 'docker' -Arguments @(
            'run', '--rm', '--user', '0:0',
            '--volume', "${volume}:/config",
            '--entrypoint', '/bin/bash', $image,
            '-ceu', 'chown 1000:1000 /config'
        ) | Out-Null
    }

    $commonRun = @(
        'run', '--rm',
        '--volume', "${configVolume}:/config",
        '--mount', "type=bind,source=$launchPath,target=/opt/windrose/launch.sh,readonly",
        '--entrypoint', '/bin/bash', $image,
        '/opt/windrose/launch.sh', '/bin/bash', '-ceu'
    )
    $missing = Invoke-Native -Command 'docker' -Arguments (
        $commonRun + 'exit 0'
    ) -AllowFailure
    if ($missing.ExitCode -eq 0 -or $missing.Output -notmatch
        'WINDROSE_SERVER_DESCRIPTION_JSON is required') {
        throw 'Missing Windrose bootstrap configuration did not fail safely.'
    }

    Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm',
        '--env', "WINDROSE_SERVER_DESCRIPTION_JSON=$validDescription",
        '--volume', "${configVolume}:/config",
        '--mount', "type=bind,source=$launchPath,target=/opt/windrose/launch.sh,readonly",
        '--entrypoint', '/bin/bash', $image,
        '/opt/windrose/launch.sh', '/bin/bash', '-ceu',
        'test -L R5/ServerDescription.json; test "$(readlink R5/ServerDescription.json)" = /config/ServerDescription.json; grep -Fq validation-a /config/ServerDescription.json; test -z "${WINDROSE_SERVER_DESCRIPTION_JSON:-}"'
    ) | Out-Null

    Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm',
        '--env', 'WINDROSE_SERVER_DESCRIPTION_JSON={"ignored":true}',
        '--volume', "${configVolume}:/config",
        '--mount', "type=bind,source=$launchPath,target=/opt/windrose/launch.sh,readonly",
        '--entrypoint', '/bin/bash', $image,
        '/opt/windrose/launch.sh', '/bin/bash', '-ceu',
        'grep -Fq validation-a /config/ServerDescription.json'
    ) | Out-Null

    $invalid = Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm',
        '--env', "WINDROSE_SERVER_DESCRIPTION_JSON=$invalidDescription",
        '--volume', "${invalidVolume}:/config",
        '--mount', "type=bind,source=$launchPath,target=/opt/windrose/launch.sh,readonly",
        '--entrypoint', '/bin/bash', $image,
        '/opt/windrose/launch.sh', '/bin/true'
    ) -AllowFailure
    if ($invalid.ExitCode -eq 0 -or $invalid.Output -notmatch
        'must enable direct connection on port 7777') {
        throw 'Windrose accepted a bootstrap configuration using port 7778.'
    }

    Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm',
        '--env', "WINDROSE_SERVER_DESCRIPTION_JSON=$reseedDescription",
        '--env', 'WINDROSE_RESEED_SERVER_DESCRIPTION=true',
        '--volume', "${configVolume}:/config",
        '--mount', "type=bind,source=$launchPath,target=/opt/windrose/launch.sh,readonly",
        '--entrypoint', '/bin/bash', $image,
        '/opt/windrose/launch.sh', '/bin/bash', '-ceu',
        'grep -Fq validation-b /config/ServerDescription.json'
    ) | Out-Null

    Invoke-Native -Command 'docker' -Arguments @(
        'run', '--detach', '--name', $containerName, '--init',
        '--stop-signal', 'SIGTERM', '--stop-timeout', '10',
        '--volume', "${configVolume}:/config",
        '--mount', "type=bind,source=$launchPath,target=/opt/windrose/launch.sh,readonly",
        '--mount', "type=bind,source=$termPath,target=/opt/windrose/term-target.sh,readonly",
        '--entrypoint', '/bin/bash', $image,
        '/opt/windrose/launch.sh', '/bin/bash', '/opt/windrose/term-target.sh'
    ) | Out-Null
    Start-Sleep -Seconds 2
    Invoke-Native -Command 'docker' -Arguments @('stop', $containerName) | Out-Null
    $exitCode = (Invoke-Native -Command 'docker' -Arguments @(
        'inspect', '--format', '{{.State.ExitCode}}', $containerName
    )).Output.Trim()
    if ($exitCode -ne '0') {
        throw "Windrose SIGTERM fixture exited with code $exitCode."
    }
    Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm', '--volume', "${configVolume}:/config",
        '--entrypoint', '/bin/bash', $image,
        '-ceu', 'grep -Fq sigterm /config/sigterm-observed'
    ) | Out-Null
    Invoke-Native -Command 'docker' -Arguments @('rm', $containerName) | Out-Null

    $lifecycle = @"
services:
  game:
    image: $image
    user: "0:0"
    restart: unless-stopped
    environment:
      FIXTURE_RELEASE: `${FIXTURE_RELEASE}
      FAIL_HEALTH: `${FAIL_HEALTH:-false}
    entrypoint: ["/bin/bash", "-ceu"]
    command:
      - |
        printf '%s\n' "`$`${FIXTURE_RELEASE}" > /state/current-release
        test -e /state/durable-save || printf 'windrose-save\n' > /state/durable-save
        trap 'exit 0' TERM
        while :; do sleep 1; done
    volumes:
      - state:/state
    healthcheck:
      test: ["CMD-SHELL", "test \"`$`$FAIL_HEALTH\" != true && test \"`$`$(cat /state/current-release)\" = \"`$`$FIXTURE_RELEASE\""]
      interval: 1s
      timeout: 1s
      retries: 3
volumes:
  state:
"@
    [System.IO.File]::WriteAllText(
        $lifecycleCompose, $lifecycle.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )

    $env:FIXTURE_RELEASE = 'v1'
    $env:FAIL_HEALTH = 'false'
    Invoke-Compose -Arguments @('up', '--detach') | Out-Null
    Wait-ForHealth -Expected healthy
    Invoke-Compose -Arguments @(
        'exec', '-T', 'game', '/bin/bash', '-ceu',
        'printf "durable-v1\n" > /state/durable-save'
    ) | Out-Null

    $env:FIXTURE_RELEASE = 'v2'
    Invoke-Compose -Arguments @('up', '--detach', '--force-recreate') | Out-Null
    Wait-ForHealth -Expected healthy
    $updated = (Invoke-Compose -Arguments @(
        'exec', '-T', 'game', '/bin/bash', '-ceu',
        'printf "%s|%s" "$(cat /state/current-release)" "$(cat /state/durable-save)"'
    )).Output.Trim()
    if ($updated -ne 'v2|durable-v1') {
        throw "Windrose update simulation lost state: $updated"
    }

    $env:FAIL_HEALTH = 'true'
    Invoke-Compose -Arguments @('up', '--detach', '--force-recreate') | Out-Null
    Wait-ForHealth -Expected unhealthy

    $env:FIXTURE_RELEASE = 'v1'
    $env:FAIL_HEALTH = 'false'
    Invoke-Compose -Arguments @('up', '--detach', '--force-recreate') | Out-Null
    Wait-ForHealth -Expected healthy
    $rolledBack = (Invoke-Compose -Arguments @(
        'exec', '-T', 'game', '/bin/bash', '-ceu',
        'printf "%s|%s" "$(cat /state/current-release)" "$(cat /state/durable-save)"'
    )).Output.Trim()
    if ($rolledBack -ne 'v1|durable-v1') {
        throw "Windrose rollback simulation lost state: $rolledBack"
    }
}
finally {
    if (Test-Path -LiteralPath $lifecycleCompose) {
        Invoke-Compose -Arguments @('down', '--volumes', '--remove-orphans') `
            -AllowFailure | Out-Null
    }
    Invoke-Native -Command 'docker' -Arguments @('rm', '--force', $containerName) `
        -AllowFailure | Out-Null
    foreach ($volume in @($configVolume, $invalidVolume)) {
        Invoke-Native -Command 'docker' -Arguments @('volume', 'rm', '--force', $volume) `
            -AllowFailure | Out-Null
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path "Env:$name" -Value $savedEnvironment[$name]
        }
    }
}

Write-Host 'Windrose image, bootstrap, SIGTERM, update, and rollback tests passed.'
