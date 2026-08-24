#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$sourceCompose = Join-Path $repositoryRoot 'games/palworld/docker-compose.yml'
$testRoot = Join-Path $repositoryRoot "build/palworld-startup-tests-$PID"
$testCompose = Join-Path $testRoot 'docker-compose.yml'
$project = "minecraftinfra-palworld-startup-$PID"

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
        'compose', '--project-name', $project, '--file', $testCompose
    ) + $Arguments
    return Invoke-Native -Command 'docker' -Arguments $allArguments `
        -AllowFailure:$AllowFailure
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Expected,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Value.Contains($Expected)) {
        throw $Message
    }
}

$savedEnvironment = @{
    TS_AUTHKEY              = $env:TS_AUTHKEY
    PALWORLD_ADMIN_PASSWORD = $env:PALWORLD_ADMIN_PASSWORD
}

try {
    $env:TS_AUTHKEY = 'tskey-auth-test-placeholder'
    $env:PALWORLD_ADMIN_PASSWORD = 'PalworldStartupTest-1234'

    $composeText = Get-Content -LiteralPath $sourceCompose -Raw -Encoding UTF8
    $image = [regex]::Match(
        $composeText,
        '(?m)^\s*image:\s*(ghcr\.io/pocketpairjp/palserver:[^\s#]+)\s*$'
    ).Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($image)) {
        throw 'The pinned Palworld image could not be read from Compose.'
    }

    $priorFailure = Invoke-Native -Command 'docker' -Arguments @(
        'run', '--rm',
        '--security-opt', 'no-new-privileges:true',
        '--entrypoint', '/bin/sh',
        $image,
        '-c', 'sudo chown user:usergroup /pal/Package/Pal/Saved'
    ) -AllowFailure
    if ($priorFailure.ExitCode -eq 0) {
        throw 'Regression setup failed: sudo unexpectedly elevated under no-new-privileges.'
    }
    Assert-Contains -Value $priorFailure.Output -Expected 'no new privileges' `
        -Message 'The prior sudo/no-new-privileges startup failure was not reproduced.'

    $model = Invoke-Native -Command 'docker' -Arguments @(
        'compose', '--file', $sourceCompose, 'config', '--format', 'json'
    )
    $config = $model.Output | ConvertFrom-Json
    $init = $config.services.'palworld-init'
    $game = $config.services.palworld

    if ($init.user -ne '0:0' -or $init.restart -ne 'no' -or
        -not $init.read_only -or $init.network_mode -ne 'none') {
        throw 'Palworld init must be a read-only, root, one-shot service with no network.'
    }
    foreach ($capability in @('CHOWN', 'DAC_READ_SEARCH')) {
        if ($init.cap_add -notcontains $capability) {
            throw "Palworld init is missing capability '$capability'."
        }
    }
    if ($init.cap_drop -notcontains 'ALL' -or
        $init.security_opt -notcontains 'no-new-privileges:true') {
        throw 'Palworld init capabilities or no-new-privileges policy regressed.'
    }
    if ($game.user -ne 'user:usergroup' -or
        $game.security_opt -notcontains 'no-new-privileges:true') {
        throw 'The Palworld game service must remain explicitly non-root with no-new-privileges.'
    }
    if ($game.depends_on.'palworld-init'.condition -ne
        'service_completed_successfully') {
        throw 'The game must wait for successful ownership initialization.'
    }
    $helperSource = Join-Path (Split-Path $sourceCompose) 'palworld-helper.sh'
    $helperText = Get-Content -LiteralPath $helperSource -Raw -Encoding UTF8
    if ($helperText -match '\bsudo\b') {
        throw 'The non-root Palworld startup helper must not invoke sudo.'
    }

    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $mount = '/data/palworld/data:/pal/Package/Pal/Saved'
    if ([regex]::Matches($composeText, [regex]::Escape($mount)).Count -ne 2) {
        throw 'Expected the init and game services to share the Palworld save mount.'
    }
    $fixture = $composeText.Replace(
        $mount,
        'palworld-startup-data:/pal/Package/Pal/Saved'
    ).Replace(
        'exec /bin/sh /pal/Package/PalServer.sh "$$@"',
        'exec "$$@"'
    ).Replace(
        'network_mode: "service:tailscale"',
        'network_mode: none'
    )
    if (-not $fixture.Contains('exec "$$@"') -or
        $fixture.Contains('exec /bin/sh /pal/Package/PalServer.sh "$$@"')) {
        throw 'The safe test-only Palworld command substitution was not applied.'
    }
    $fixture += @"

volumes:
  palworld-startup-data:
"@
    $fixture = $fixture.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText(
        $testCompose,
        $fixture,
        [System.Text.UTF8Encoding]::new($false)
    )
    Copy-Item -LiteralPath (Join-Path (Split-Path $sourceCompose) 'palworld-init.sh') `
        -Destination (Join-Path $testRoot 'palworld-init.sh')
    $testHelper = $helperText.Replace(
        'exec /bin/sh /pal/Package/PalServer.sh "$@"',
        'exec "$@"'
    ).Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText(
        (Join-Path $testRoot 'palworld-helper.sh'),
        $testHelper,
        [System.Text.UTF8Encoding]::new($false)
    )

    Invoke-Compose -Arguments @('down', '--volumes', '--remove-orphans') `
        -AllowFailure | Out-Null
    Invoke-Compose -Arguments @(
        'up', '--abort-on-container-exit', '--exit-code-from', 'palworld-init',
        'palworld-init'
    ) |
        Out-Null
    $check = @'
set -eu
saved=/pal/Package/Pal/Saved
settings="$saved/Config/LinuxServer/PalWorldSettings.ini"
test "$(id -u)" != 0
test "$(stat -c %u "$saved")" = "$(id -u)"
test "$(awk '/^NoNewPrivs:/ { print $2 }' /proc/self/status)" = 1
test -w "$saved"
touch "$saved/startup-regression-check"
grep -Fq "AdminPassword=\"$PALWORLD_ADMIN_PASSWORD\"" "$settings"
grep -Fq 'RCONEnabled=False' "$settings"
grep -Fq 'RESTAPIEnabled=True' "$settings"
grep -Fq 'RESTAPIPort=8212' "$settings"
if sudo true 2>"$saved/sudo-error"; then
  echo "sudo unexpectedly elevated in the game container" >&2
  exit 1
fi
grep -qi 'no new privileges' "$saved/sudo-error"
'@
    $check = $check.Replace("`r`n", "`n")
    Invoke-Compose -Arguments @(
        'run', '--rm', '--no-deps', 'palworld',
        '/bin/sh', '-c', $check
    ) | Out-Null
} finally {
    if (Test-Path -LiteralPath $testCompose) {
        Invoke-Compose -Arguments @('down', '--volumes', '--remove-orphans') `
            -AllowFailure | Out-Null
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$name" -Value $savedEnvironment[$name]
        }
    }
}

Write-Host 'Palworld prior startup failure and secure one-shot initialization passed.'
