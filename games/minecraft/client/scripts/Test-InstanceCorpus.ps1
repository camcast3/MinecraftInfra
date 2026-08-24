#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Could not resolve the repository root.' }
$work = Join-Path $repoRoot '.artifacts\corpus-ci'
$instances = Join-Path $work 'instances'
$instance = Join-Path $instances 'Synthetic C2E2'
$mc = Join-Path $instance '.minecraft'
$artifactRoot = Join-Path $work 'output'

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $mc 'mods'), (Join-Path $mc 'config') -Force | Out-Null
try {
    @'
[General]
ConfigVersion=1.2
name=Synthetic C2E2
'@ | Set-Content -LiteralPath (Join-Path $instance 'instance.cfg') -Encoding UTF8
    '{"components":[{"uid":"net.minecraft","version":"1.20.1"}],"formatVersion":1}' |
        Set-Content -LiteralPath (Join-Path $instance 'mmc-pack.json') -Encoding UTF8
    'synthetic-jar' | Set-Content -LiteralPath (Join-Path $mc 'mods\synthetic.jar') -Encoding ASCII
    'player-token=must-not-leak' | Set-Content -LiteralPath (Join-Path $mc 'options.txt') -Encoding UTF8
    'access_token=must-be-redacted' | Set-Content -LiteralPath (Join-Path $mc 'config\synthetic.toml') -Encoding UTF8
    '{"auth":{"access_token":"must-not-leak","nested":{"client_secret":"also-secret"}}}' |
        Set-Content -LiteralPath (Join-Path $mc 'config\credentials.json') -Encoding UTF8
    "password: yaml-secret`nnormal: retained" |
        Set-Content -LiteralPath (Join-Path $mc 'config\synthetic.yaml') -Encoding UTF8
    [IO.File]::WriteAllBytes((Join-Path $mc 'config\unknown.bin'), [byte[]](0, 1, 2, 3))
    '1.0.0' | Set-Content -LiteralPath (Join-Path $instance '.negativezone-version') -Encoding ASCII

    & (Join-Path $PSScriptRoot 'build-instance-corpus.ps1') `
        -InstancesRoot $instances -ArtifactRoot $artifactRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Corpus compatibility harness failed with exit code $LASTEXITCODE"
    }

    $reportPath = Get-ChildItem -LiteralPath $artifactRoot -Filter report.json -Recurse |
        Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
    if (-not $reportPath) {
        throw 'Corpus compatibility harness did not emit report.json.'
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $case = @($report.candidates)[0]
    if ($case.status -ne 'copied' -or $case.compatibility -ne 'passed') {
        throw "Corpus case did not pass: $($case | ConvertTo-Json -Compress)"
    }
    $snapshot = Join-Path (Split-Path $reportPath) 'snapshots\instance-001\payload'
    $snapshotText = Get-ChildItem -LiteralPath $snapshot -File -Recurse |
        Where-Object { $_.Extension -in @('.json', '.toml', '.yaml') } |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } |
        Out-String
    if ($snapshotText -match 'must-not-leak|also-secret|yaml-secret|must-be-redacted') {
        throw 'Sanitized corpus retained a synthetic credential.'
    }
    if (Test-Path -LiteralPath (Join-Path $snapshot '.minecraft\config\unknown.bin')) {
        throw 'Sanitized corpus copied an unsupported raw binary file.'
    }
} finally {
    Get-ChildItem -LiteralPath $work -File -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Synthetic immutable corpus compatibility passed.'
