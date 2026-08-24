#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Could not resolve the repository root.' }
$work = Join-Path $repoRoot '.artifacts\packaging-ci'
$instance = Join-Path $work 'source\Craft to Exile 2'
$out = Join-Path $work 'out'
$mc = Join-Path $instance '.minecraft'

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $mc 'mods'), (Join-Path $mc 'config'), $out -Force | Out-Null
try {
    @'
[General]
ConfigVersion=1.2
name=Unsanitized local name
OverrideCommands=false
JavaPath=C:\private\java.exe
'@ | Set-Content -LiteralPath (Join-Path $instance 'instance.cfg') -Encoding UTF8
    '{"components":[{"uid":"net.minecraft","version":"1.20.1"}],"formatVersion":1}' |
        Set-Content -LiteralPath (Join-Path $instance 'mmc-pack.json') -Encoding UTF8
    'synthetic-jar' | Set-Content -LiteralPath (Join-Path $mc 'mods\synthetic.jar') -Encoding ASCII
    'private' | Set-Content -LiteralPath (Join-Path $mc 'options.txt') -Encoding UTF8

    & (Join-Path $repoRoot 'infra\azure\scripts\publish-prism-pack.ps1') `
        -Version 'test-package' -InstancePath $instance -LocalOutDir $out `
        -LocalBaseUrl 'http://127.0.0.1:1'
    if ($LASTEXITCODE -ne 0) {
        throw "Local packaging failed with exit code $LASTEXITCODE"
    }

    $manifestPath = Join-Path $out 'c2e2-vtest-package.json'
    $zipPath = Join-Path $out 'c2e2-vtest-package.zip'
    $preservePath = Join-Path $out 'c2e2-vtest-package-preserve-list.json'
    if (-not (Test-Path -LiteralPath $manifestPath) -or
        -not (Test-Path -LiteralPath $zipPath) -or
        -not (Test-Path -LiteralPath $preservePath)) {
        throw 'Packaging did not emit versioned manifest, preserve list, and zip.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifest.sha256 -ne $actualHash -or $manifest.compatibility.preserveListSchema -ne 1) {
        throw 'Versioned package manifest checksum or compatibility metadata is invalid.'
    }
    if ($manifest.preserveListUrl -ne
        'http://127.0.0.1:1/c2e2-vtest-package-preserve-list.json') {
        throw 'Versioned package manifest does not reference its immutable preserve list.'
    }
    $preserve = Get-Content -LiteralPath $preservePath -Raw | ConvertFrom-Json
    if ($preserve.version -ne 1 -or $null -eq $preserve.preserve) {
        throw 'Standalone preserve-list manifest is invalid.'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($zip.Entries.FullName)
        foreach ($required in @(
            'Craft to Exile 2/.minecraft/mods/synthetic.jar',
            'Craft to Exile 2/.negativezone/preserve-list.json'
        )) {
            if ($names -notcontains $required) {
                throw "Packaged zip is missing $required"
            }
        }
        if ($names -contains 'Craft to Exile 2/.minecraft/options.txt') {
            throw 'Packaged zip leaked excluded player options.'
        }
        foreach ($legacy in @(
            'Craft to Exile 2/.negativezone/update.ps1',
            'Craft to Exile 2/.negativezone/backup.ps1',
            'Craft to Exile 2/.negativezone/prelaunch-check.ps1'
        )) {
            if ($names -contains $legacy) {
                throw "Packaged zip still contains retired client artifact $legacy"
            }
        }

        $cfgEntry = $zip.GetEntry('Craft to Exile 2/instance.cfg')
        if (-not $cfgEntry) {
            throw 'Packaged zip is missing sanitized instance.cfg.'
        }
        $reader = [IO.StreamReader]::new($cfgEntry.Open())
        try {
            $cfg = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
        if ($cfg -notmatch '(?m)^OverrideCommands=false\r?$' -or
            $cfg -match '(?m)^(PreLaunchCommand|PostExitCommand)=') {
            throw 'Packaged instance.cfg must defer all client hooks to nz setup.'
        }
    } finally {
        $zip.Dispose()
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Disposable packaging validation passed.'
