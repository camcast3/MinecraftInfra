#requires -Version 7.0
<#
.SYNOPSIS
    Provision a self-contained LOCAL sandbox for manually driving the `nz`
    client end-to-end, including a local 0.4.3 zip setup-upgrade flow,
    without touching your real Prism instance or production Azure.

.DESCRIPTION
    `up`   builds nz.exe, stages a fake "Azure" (local HTTP server serving a
           manifest + real local 0.4.2/0.4.3 modpack zips), creates a sandbox
           %APPDATA% with a second "old" instance for migrate, and writes an
           env.ps1 you dot-source to load everything (env vars + `nz`,
           `nzPublish`, `nzPublishReal`, `nzStageZip`, `nzReset` helpers).
    `down` stops the server and removes the sandbox.

    Nothing here hits production Azure, the real CurseForge, or your real
    PrismLauncher instances — everything is loopback + a temp sandbox.

    By default the update path uses the NEGATIVEZONE_PACKWIZ_CMD fake seam so
    `nz update` runs instantly offline (no Java / no real packwiz). Pass
    -RealPackwiz to exercise the real packwiz-installer instead (needs Java 17
    + network; point packwizUrl at a real SHA-pinned pack.toml via nzPublish).

.EXAMPLE
    pwsh client/scripts/manual-e2e.ps1 up
    . $env:TEMP\nz-manual-e2e\env.ps1
    $env:NEGATIVEZONE_NONINTERACTIVE='1'
    nzPublishReal 0.4.3 ; nz setup  # brand-new v0.4.3 from the local zip

.EXAMPLE
    pwsh client/scripts/manual-e2e.ps1 up
    . $env:TEMP\nz-manual-e2e\env.ps1
    $env:NEGATIVEZONE_NONINTERACTIVE='1'
    nzReset
    nzPublishReal 0.4.2 ; nz setup  # fresh install base v0.4.2 local zip
    nzPublishReal 0.4.3 ; nz setup  # upgrade via local v0.4.3 zip

.EXAMPLE
    pwsh client/scripts/manual-e2e.ps1 up
    . $env:TEMP\nz-manual-e2e\env.ps1
    $env:NEGATIVEZONE_NONINTERACTIVE='1'
    nz setup        # fresh install v0.4.2 from the local zip
    nz check
    nz backup
    nzPublish 0.4.3 # bump the "published" version for packwiz update testing
    nz check        # now reports behind
    nz update       # packwiz delta-sync (fake), version -> 0.4.3
    nz migrate      # pick the "(old)" instance as source

.EXAMPLE
    pwsh client/scripts/manual-e2e.ps1 down
#>

[CmdletBinding()]
param(
    [ValidateSet('up', 'down')]
    [string] $Action = 'up',
    [int]    $Port = 8799,
    [switch] $RealPackwiz
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Could not resolve the repository root.' }
$clientDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$sandbox = Join-Path $env:TEMP 'nz-manual-e2e'
$blobDir = Join-Path $sandbox 'blob'
$appData = Join-Path $sandbox 'appdata'
$nzExe   = Join-Path $sandbox 'nz.exe'
$pidFile = Join-Path $sandbox 'server.pid'
$envFile = Join-Path $sandbox 'env.ps1'
$instanceName = 'Craft to Exile 2'

function Write-Head($t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

function Stop-Server {
    if (Test-Path -LiteralPath $pidFile) {
        $serverPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($serverPid) {
            $p = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
            if ($p) { Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
}

if ($Action -eq 'down') {
    Stop-Server
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "Sandbox torn down: $sandbox" -ForegroundColor Green
    return
}

# ─── up ──────────────────────────────────────────────────────────────────────
Stop-Server
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $blobDir, $appData -Force | Out-Null

# 1. Build nz.exe
Write-Head 'Building nz.exe...'
Push-Location $clientDir
try {
    & go build -o $nzExe ./cmd/nz/
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
Write-Host "  -> $nzExe"

# 2. Fake modpack zip builder (mirrors the published-zip layout setup expects)
function New-FakeZip {
    param([Parameter(Mandatory)][string] $Version)
    $stage   = Join-Path $sandbox ("stage-{0}" -f $Version)
    $instDir = Join-Path $stage $instanceName
    $mcDir   = Join-Path $instDir '.minecraft'
    $nzDir   = Join-Path $instDir '.negativezone'
    New-Item -ItemType Directory -Path (Join-Path $mcDir 'mods'), $nzDir -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $mcDir "mods\stub-v$Version.jar") -Value "stub-mod-$Version" -Encoding ASCII
    @"
[General]
ConfigVersion=1.2
iconKey=cte2
InstanceType=OneSix
name=$instanceName v$Version
OverrideCommands=true
"@ | Set-Content -LiteralPath (Join-Path $instDir 'instance.cfg') -Encoding UTF8
    '{"components":[{"uid":"net.minecraft","version":"1.20.1"}],"formatVersion":1}' |
        Set-Content -LiteralPath (Join-Path $instDir 'mmc-pack.json') -Encoding UTF8
    '{"preserve":["config/test-mod-prefs.json"],"version":1}' |
        Set-Content -LiteralPath (Join-Path $nzDir 'preserve-list.json') -Encoding UTF8

    $zipPath = Join-Path $blobDir "c2e2-v$Version.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path $instDir -DestinationPath $zipPath -CompressionLevel Fastest -Force
    Remove-Item -LiteralPath $stage -Recurse -Force
    return $zipPath
}

# 3. Manifest writer (real sha/size so `nz setup` zip verification passes)
function Write-LocalManifest {
    param([Parameter(Mandatory)][string] $Version, [switch] $AllowDowngrade)
    $zip = Join-Path $blobDir "c2e2-v$Version.zip"
    $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    $size = (Get-Item -LiteralPath $zip).Length
    $m = [ordered]@{
        version    = $Version
        instance   = $instanceName
        url        = "http://127.0.0.1:$Port/c2e2-v$Version.zip"
        sha256     = $sha
        sizeBytes  = $size
        # Placeholder for the fake-packwiz path; nzPublish/-RealPackwiz can
        # point this at a real SHA-pinned pack.toml.
        packwizUrl = "http://127.0.0.1:$Port/pack.toml"
    }
    if ($AllowDowngrade) { $m['allowDowngrade'] = $true }
    [IO.File]::WriteAllText((Join-Path $blobDir 'latest.json'),
        ($m | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $blobDir 'latest-version.txt'),
        "$Version`n", [Text.UTF8Encoding]::new($false))
}

Write-Head 'Staging real local modpack zips + manifest (v0.4.2, v0.4.3)...'
[void](New-FakeZip -Version '0.4.2')
[void](New-FakeZip -Version '0.4.3')
Write-LocalManifest -Version '0.4.2'
# Minimal pack.toml so a curious -RealPackwiz run doesn't 404 on the placeholder.
'name = "Craft to Exile 2"' | Set-Content -LiteralPath (Join-Path $blobDir 'pack.toml') -Encoding UTF8
Write-Host "  -> $blobDir"

# 4. Tiny static file server (compiled, run detached so it survives this shell)
Write-Head "Starting local blob server on http://127.0.0.1:$Port ..."
$srvGo = Join-Path $sandbox 'server.go'
@'
package main

import (
	"log"
	"net/http"
	"os"
)

func main() {
	http.Handle("/", http.FileServer(http.Dir(os.Args[1])))
	log.Fatal(http.ListenAndServe(os.Args[2], nil))
}
'@ | Set-Content -LiteralPath $srvGo -Encoding ASCII
$srvExe = Join-Path $sandbox 'blobserver.exe'
Push-Location $clientDir
try {
    & go build -o $srvExe $srvGo
    if ($LASTEXITCODE -ne 0) { throw "server build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
$proc = Start-Process -FilePath $srvExe -ArgumentList @($blobDir, "127.0.0.1:$Port") -WindowStyle Hidden -PassThru
$proc.Id | Set-Content -LiteralPath $pidFile -Encoding ASCII
Start-Sleep -Milliseconds 400
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/latest.json" -UseBasicParsing -TimeoutSec 5
    Write-Host "  -> server up (PID $($proc.Id))"
} catch {
    throw "Blob server failed to start on port $Port. $_"
}

# 5. Pre-stage a second "(old)" instance for `nz migrate` to copy settings FROM
Write-Head 'Staging an "(old)" instance for migrate...'
$oldInst = Join-Path $appData "PrismLauncher\instances\$instanceName (old)"
$oldMc = Join-Path $oldInst '.minecraft'
New-Item -ItemType Directory -Path (Join-Path $oldMc 'XaeroWorldMap\sp'), (Join-Path $oldMc 'journeymap') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $oldMc 'options.txt')   -Value 'mouseSensitivity:0.37' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $oldMc 'optionsof.txt') -Value 'renderDistance:24' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $oldMc 'XaeroWorldMap\sp\waypoint.json') -Value '{"home":true}' -Encoding ASCII
Write-Host "  -> $oldInst"

# 6. Generate env.ps1 (dot-source to load the sandbox)
# NOTE: nz's runOverride already invokes the value via `cmd /c <override>`, so
# the fake seam must be a BARE cmd command — no leading `cmd /c` and no inner
# double quotes (Go's Windows exec escapes embedded quotes as \" which cmd then
# rejects). Avoid `if not exist mods (...)`: cmd groups the whole `&`-tail inside
# the if, so the echo is skipped whenever mods\ already exists (it does after
# setup). `mkdir mods 2>nul & echo ...` always runs the echo and exits 0.
$fakePackwizLine = if ($RealPackwiz) {
    '# (RealPackwiz) NEGATIVEZONE_PACKWIZ_CMD intentionally unset — uses real Java + packwiz-installer.'
} else {
    '$env:NEGATIVEZONE_PACKWIZ_CMD = ''mkdir mods 2>nul & echo synced> mods\packwiz-synced.txt'''
}

$env_ps1 = @"
# Dot-source this to load the nz manual-e2e sandbox: . '$envFile'
`$nz = '$nzExe'   # full path to the test nz.exe
`$env:APPDATA = '$appData'
`$env:NEGATIVEZONE_MANIFEST_URL       = 'http://127.0.0.1:$Port/latest.json'
`$env:NEGATIVEZONE_LATEST_VERSION_URL = 'http://127.0.0.1:$Port/latest-version.txt'
`$env:NEGATIVEZONE_SKIP_PRISM_CHECK   = '1'   # sandbox has no real Prism
`$env:NEGATIVEZONE_BACKUP_DAYS        = '0'   # always snapshot (skip 3-day cadence)
`$env:NEGATIVEZONE_LOG_DIR            = '$sandbox\globallog'   # keep the global fallback nz.log in the sandbox
$fakePackwizLine

function nz { & '$nzExe' @args }

# Build/replace a real local modpack zip with the same layout nz setup expects.
function nzStageZip {
    param([Parameter(Mandatory)][string] `$Version)
    `$blob = '$blobDir'
    `$sandbox = '$sandbox'
    `$instance = '$instanceName'
    `$stage = Join-Path `$sandbox ("stage-{0}" -f `$Version)
    if (Test-Path -LiteralPath `$stage) { Remove-Item -LiteralPath `$stage -Recurse -Force }
    `$instDir = Join-Path `$stage `$instance
    `$mcDir = Join-Path `$instDir '.minecraft'
    `$nzDir = Join-Path `$instDir '.negativezone'
    New-Item -ItemType Directory -Path (Join-Path `$mcDir 'mods'), `$nzDir -Force | Out-Null

    Set-Content -LiteralPath (Join-Path `$mcDir "mods\stub-v`$Version.jar") -Value "stub-mod-`$Version" -Encoding ASCII
    @(
        '[General]'
        'ConfigVersion=1.2'
        'iconKey=cte2'
        'InstanceType=OneSix'
        "name=`$instance v`$Version"
        'OverrideCommands=true'
    ) | Set-Content -LiteralPath (Join-Path `$instDir 'instance.cfg') -Encoding UTF8
    '{"components":[{"uid":"net.minecraft","version":"1.20.1"}],"formatVersion":1}' |
        Set-Content -LiteralPath (Join-Path `$instDir 'mmc-pack.json') -Encoding UTF8
    '{"preserve":["config/test-mod-prefs.json"],"version":1}' |
        Set-Content -LiteralPath (Join-Path `$nzDir 'preserve-list.json') -Encoding UTF8

    `$zipPath = Join-Path `$blob "c2e2-v`$Version.zip"
    if (Test-Path -LiteralPath `$zipPath) { Remove-Item -LiteralPath `$zipPath -Force }
    Compress-Archive -Path `$instDir -DestinationPath `$zipPath -CompressionLevel Fastest -Force
    Remove-Item -LiteralPath `$stage -Recurse -Force
    Write-Host "staged real local zip v`$Version -> `$zipPath" -ForegroundColor Green
    return `$zipPath
}

# Publish a manifest that points at a real local zip with real sha256 + size, so
# nz setup downloads and verifies the loopback zip instead of Azure storage.
function nzPublishReal {
    param([Parameter(Mandatory)][string] `$Version, [switch] `$AllowDowngrade)
    `$blob = '$blobDir'
    `$zip = Join-Path `$blob "c2e2-v`$Version.zip"
    if (-not (Test-Path -LiteralPath `$zip)) { `$zip = nzStageZip `$Version }
    `$sha = (Get-FileHash -LiteralPath `$zip -Algorithm SHA256).Hash.ToLower()
    `$size = (Get-Item -LiteralPath `$zip).Length
    `$m = [ordered]@{
        version=`$Version; instance='$instanceName'
        url="http://127.0.0.1:$Port/c2e2-v`$Version.zip"
        sha256=`$sha; sizeBytes=`$size
        packwizUrl="http://127.0.0.1:$Port/pack.toml"
    }
    if (`$AllowDowngrade) { `$m['allowDowngrade'] = `$true }
    [IO.File]::WriteAllText((Join-Path `$blob 'latest.json'), (`$m | ConvertTo-Json), [Text.UTF8Encoding]::new(`$false))
    [IO.File]::WriteAllText((Join-Path `$blob 'latest-version.txt'), "`$Version``n", [Text.UTF8Encoding]::new(`$false))
    Write-Host "published real local zip v`$Version (sha256 `$(`$sha.Substring(0, 12))..., `$size bytes)" -ForegroundColor Green
}

# Re-publish a different "latest" version to trigger an update/downgrade.
# Note: sha256 is a placeholder here (fine for the packwiz update path, which
# does not download the zip). Re-run with -RealPackwiz off for instant updates.
function nzPublish {
    param([Parameter(Mandatory)][string] `$Version, [switch] `$AllowDowngrade)
    `$blob = '$blobDir'
    `$m = [ordered]@{
        version=`$Version; instance='$instanceName'
        url="http://127.0.0.1:$Port/c2e2-v`$Version.zip"
        sha256='0'; sizeBytes=0
        packwizUrl="http://127.0.0.1:$Port/pack.toml"
    }
    if (`$AllowDowngrade) { `$m['allowDowngrade'] = `$true }
    [IO.File]::WriteAllText((Join-Path `$blob 'latest.json'), (`$m | ConvertTo-Json), [Text.UTF8Encoding]::new(`$false))
    [IO.File]::WriteAllText((Join-Path `$blob 'latest-version.txt'), "`$Version``n", [Text.UTF8Encoding]::new(`$false))
    Write-Host "published v`$Version" -ForegroundColor Green
}

# Wipe the installed instance(s) for a clean setup run.
function nzReset {
    `$inst = Join-Path `$env:APPDATA 'PrismLauncher\instances\$instanceName'
    if (Test-Path -LiteralPath `$inst)         { Remove-Item -LiteralPath `$inst -Recurse -Force }
    if (Test-Path -LiteralPath "`$inst.bak")   { Remove-Item -LiteralPath "`$inst.bak" -Recurse -Force }
    Write-Host 'instance reset — run setup for a fresh install' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Sandbox loaded. Run commands as:  & `$nz setup   (or: nz setup)' -ForegroundColor Magenta
Write-Host ("  `$nz     = " + `$nz)
Write-Host ("  APPDATA = " + `$env:APPDATA)
Write-Host 'Helpers:  nzPublish <ver> [-AllowDowngrade] | nzPublishReal <ver> [-AllowDowngrade] | nzStageZip <ver> | nzReset'
"@
Set-Content -LiteralPath $envFile -Value $env_ps1 -Encoding UTF8

# ─── Runbook ────────────────────────────────────────────────────────────────
$mode = if ($RealPackwiz) { 'REAL packwiz (needs Java 17 + network)' } else { 'fake packwiz (offline, instant)' }
Write-Host ''
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host ' nz manual end-to-end sandbox is READY' -ForegroundColor Green
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host "  sandbox : $sandbox"
Write-Host "  nz.exe  : $nzExe"
Write-Host "  server  : http://127.0.0.1:$Port  (PID $($proc.Id))  <- serves the local manifest + zips"
Write-Host "  update  : $mode"
Write-Host ''
Write-Host ' STEP 1 (REQUIRED — sets sandbox APPDATA + helpers for THIS shell):' -ForegroundColor Yellow
Write-Host "      . '$envFile'"
Write-Host '   Without this, the commands below do nothing / target the wrong place.' -ForegroundColor DarkGray
Write-Host ''
Write-Host ' STEP 2A — local-zip setup scenarios:' -ForegroundColor Cyan
Write-Host "      `$env:NEGATIVEZONE_NONINTERACTIVE='1'"
Write-Host '      nzReset ; nzPublishReal 0.4.3 ; & $nz setup  # brand-new instance from LOCAL v0.4.3 zip'
Write-Host ''
Write-Host '      # Full upgrade flow that creates .bak, "(old)", and Prism groups:'
Write-Host '      nzReset ; nzPublishReal 0.4.2 ; & $nz setup  # installs base v0.4.2 local zip'
Write-Host '      nzPublishReal 0.4.3 ; & $nz setup            # upgrades from LOCAL v0.4.3 zip'
Write-Host ''
Write-Host ' STEP 2B — existing packwiz update/migrate path (use after nzReset for a clean run):' -ForegroundColor Cyan
Write-Host '      nzReset                              # keeps the staged "(old)" migrate fixture'
Write-Host "      & `$nz setup                         # installs v0.4.2 (answer y or keep NONINTERACTIVE=1)"
Write-Host "      & `$nz check                         # in-sync -> exits 0 silently"
Write-Host "      & `$nz backup                        # snapshots user-state into .negativezone\backups"
Write-Host '      nzPublish 0.4.3                      # bump the "published" version for packwiz update'
Write-Host "      & `$nz check                         # now reports BEHIND (exit 1)"
Write-Host "      & `$nz update                        # delta-sync -> version becomes 0.4.3"
Write-Host "      & `$nz migrate                       # copy settings from the `"(old)`" instance"
Write-Host ''
Write-Host '    Extra scenarios:' -ForegroundColor Cyan
Write-Host '      nzStageZip 0.4.4 ; nzPublishReal 0.4.4 ; & $nz setup  # another local-zip setup upgrade'
Write-Host '      nzReset ; & $nz setup                                  # fresh install again'
Write-Host '      nzPublish 0.4.1 ; & $nz update                         # refused (no downgrade)'
Write-Host '      nzPublish 0.4.1 -AllowDowngrade ; & $nz update         # downgrade allowed'
Write-Host '      $env:NEGATIVEZONE_SKIP_VERSION_CHECK=1 ; & $nz check   # bypass gate'
Write-Host ''
Write-Host ' STEP 3 — tear down when done:' -ForegroundColor Cyan
Write-Host "      pwsh '$($PSCommandPath)' down"
Write-Host ''
