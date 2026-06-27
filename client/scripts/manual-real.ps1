#requires -Version 7.0
<#
.SYNOPSIS
    Drive the `nz` client manually against your REAL Prism "Craft to Exile 2"
    instance — safely. Read-only/additive commands (check, backup) are safe;
    `update` runs the REAL packwiz-installer pinned to the SHA that matches your
    installed mods, which is a verified NO-OP sync (no mod changes), and the
    version marker is auto-revertable.

.DESCRIPTION
    `up`   records your current version marker, starts a tiny local server that
           serves a manifest + version pointer YOU control (so check/update don't
           depend on the rate-limited GitHub pointer or production state), and
           writes an env.ps1 you dot-source. packwizUrl is pinned to the
           published SHA whose packwiz manifest equals your installed 392 mods,
           so `nz update` syncs nothing.
    `down` stops the server and RESTORES your original version marker.

    Guardrails:
      * The Prism-running check stays ON (update refuses while Prism is open).
      * `nz setup`'s manifest `url` points at a non-existent local zip, so a
        stray `nz setup` fails fast WITHOUT touching your real .minecraft. Do
        setup testing in the sandbox (manual-e2e.ps1), not here.
      * `nzRevert` restores the version marker any time; `down` also restores it.

.EXAMPLE
    pwsh client/scripts/manual-real.ps1 up
    . $env:TEMP\nz-manual-real\env.ps1
    nz check                 # in-sync (exit 0)
    nz backup                # snapshots your real Xaero maps / configs
    nzPublish 0.4.3          # pretend a new version shipped
    nz check                 # now BEHIND (exit 1)
    nz update                # REAL packwiz no-op sync; version -> 0.4.3
    nzRevert                 # version marker back to original
    pwsh client/scripts/manual-real.ps1 down
#>

[CmdletBinding()]
param(
    [ValidateSet('up', 'down')]
    [string] $Action = 'up',
    [int]    $Port = 8798,
    [string] $InstancePath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$clientDir = Join-Path $repoRoot 'client'

if (-not $InstancePath) {
    $InstancePath = Join-Path $env:APPDATA 'PrismLauncher\instances\Craft to Exile 2'
}

$state    = Join-Path $env:TEMP 'nz-manual-real'
$blobDir  = Join-Path $state 'blob'
$nzExe    = Join-Path $state 'nz.exe'
$pidFile  = Join-Path $state 'server.pid'
$origVer  = Join-Path $state 'orig-version.txt'
$envFile  = Join-Path $state 'env.ps1'
$verMarker = Join-Path $InstancePath '.negativezone-version'

function Write-Head($t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

function Stop-Server {
    if (Test-Path -LiteralPath $pidFile) {
        $serverPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($serverPid -and (Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
}

if ($Action -eq 'down') {
    Stop-Server
    # Restore the original version marker if we recorded one.
    if ((Test-Path -LiteralPath $origVer) -and (Test-Path -LiteralPath $InstancePath)) {
        $v = (Get-Content -LiteralPath $origVer -Raw).Trim()
        Set-Content -LiteralPath $verMarker -Value $v -NoNewline -Encoding ASCII
        Write-Host "Restored version marker -> $v" -ForegroundColor Green
    }
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host 'Real-instance harness torn down.' -ForegroundColor Green
    return
}

# ─── up ──────────────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath (Join-Path $InstancePath '.minecraft'))) {
    throw "No .minecraft under '$InstancePath'. Is this the right instance? Pass -InstancePath."
}

Stop-Server
if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Recurse -Force }
New-Item -ItemType Directory -Path $blobDir -Force | Out-Null

# Record the original version marker so we can always revert.
$installedVersion = if (Test-Path -LiteralPath $verMarker) {
    (Get-Content -LiteralPath $verMarker -Raw).Trim()
} else { '0.0.0' }
Set-Content -LiteralPath $origVer -Value $installedVersion -NoNewline -Encoding ASCII

# Resolve the safe packwiz SHA: the published PACKWIZ_URL SHA whose manifest
# matches the installed mods (so a real sync downloads nothing). Verify packwiz/
# hasn't drifted from it; fall back to HEAD if the compose value is missing.
$composePath = Join-Path $repoRoot 'docker\proxmox\docker-compose.yml'
$safeSha = $null
if (Test-Path -LiteralPath $composePath) {
    $c = Get-Content -LiteralPath $composePath -Raw
    if ($c -match 'PACKWIZ_URL:\s*"https://raw\.githubusercontent\.com/camcast3/MinecraftInfra/([0-9a-f]{40})/packwiz/pack\.toml"') {
        $safeSha = $Matches[1]
    }
}
if (-not $safeSha) { $safeSha = (git -C $repoRoot rev-parse HEAD).Trim() }
$drift = git -C $repoRoot diff --name-only $safeSha HEAD -- packwiz/ 2>$null
if ($drift) {
    Write-Host "  [warn] packwiz/ has changed since $safeSha — a sync may download real mod deltas." -ForegroundColor Yellow
} else {
    Write-Host "  packwiz pinned to $safeSha (matches installed mods -> update is a NO-OP)" -ForegroundColor DarkGray
}
$packwizUrl = "https://raw.githubusercontent.com/camcast3/MinecraftInfra/$safeSha/packwiz/pack.toml"

# Build nz.exe
Write-Head 'Building nz.exe...'
Push-Location $clientDir
try {
    & go build -o $nzExe ./cmd/nz/
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
Write-Host "  -> $nzExe"

# Manifest writer. `url` points at a local zip we deliberately DO NOT create,
# so a stray `nz setup` fails fast on download (404) without touching .minecraft.
function Write-RealManifest {
    param([Parameter(Mandatory)][string] $Version, [switch] $AllowDowngrade)
    $m = [ordered]@{
        version    = $Version
        instance   = 'Craft to Exile 2'
        url        = "http://127.0.0.1:$Port/DO-NOT-USE-setup-here.zip"
        sha256     = '0'
        sizeBytes  = 0
        packwizUrl = $packwizUrl
    }
    if ($AllowDowngrade) { $m['allowDowngrade'] = $true }
    [IO.File]::WriteAllText((Join-Path $blobDir 'latest.json'),
        ($m | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $blobDir 'latest-version.txt'),
        "$Version`n", [Text.UTF8Encoding]::new($false))
}
# Start in-sync: manifest + pointer both at the installed version.
Write-RealManifest -Version $installedVersion

# Tiny static file server (compiled, detached so it survives this shell)
Write-Head "Starting local manifest server on http://127.0.0.1:$Port ..."
$srvGo = Join-Path $state 'server.go'
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
$srvExe = Join-Path $state 'blobserver.exe'
Push-Location $clientDir
try {
    & go build -o $srvExe $srvGo
    if ($LASTEXITCODE -ne 0) { throw "server build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
$proc = Start-Process -FilePath $srvExe -ArgumentList @($blobDir, "127.0.0.1:$Port") -WindowStyle Hidden -PassThru
$proc.Id | Set-Content -LiteralPath $pidFile -Encoding ASCII
Start-Sleep -Milliseconds 400
$null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/latest.json" -UseBasicParsing -TimeoutSec 5
Write-Host "  -> server up (PID $($proc.Id))"

# Generate env.ps1 (only needed for the UPDATE demo, which uses the local
# manifest server + helper functions). check/backup work without this.
$env_ps1 = @"
# Dot-source to load the UPDATE-demo env + helpers: . '$envFile'
`$nz = '$nzExe'   # full path to the test nz.exe
`$env:INST_DIR                        = '$InstancePath'
`$env:NEGATIVEZONE_MANIFEST_URL       = 'http://127.0.0.1:$Port/latest.json'
`$env:NEGATIVEZONE_LATEST_VERSION_URL = 'http://127.0.0.1:$Port/latest-version.txt'
`$env:NEGATIVEZONE_BACKUP_DAYS        = '0'    # always snapshot
`$env:NEGATIVEZONE_BACKUP_RETAIN      = '50'   # don't prune your existing snapshots
`$env:NEGATIVEZONE_LOG_DIR            = '$state\globallog'   # keep the global fallback nz.log out of %LOCALAPPDATA%
# Prism-running guard left ON. Close Prism before 'update'.

function nz { & '$nzExe' @args }

# Pretend a new version shipped (manifest + pointer). packwizUrl stays pinned to
# the safe SHA, so 'nz update' is a real but NO-OP sync.
function nzPublish {
    param([Parameter(Mandatory)][string] `$Version, [switch] `$AllowDowngrade)
    `$blob = '$blobDir'
    `$m = [ordered]@{
        version=`$Version; instance='Craft to Exile 2'
        url="http://127.0.0.1:$Port/DO-NOT-USE-setup-here.zip"
        sha256='0'; sizeBytes=0
        packwizUrl='$packwizUrl'
    }
    if (`$AllowDowngrade) { `$m['allowDowngrade'] = `$true }
    [IO.File]::WriteAllText((Join-Path `$blob 'latest.json'), (`$m | ConvertTo-Json), [Text.UTF8Encoding]::new(`$false))
    [IO.File]::WriteAllText((Join-Path `$blob 'latest-version.txt'), "`$Version``n", [Text.UTF8Encoding]::new(`$false))
    Write-Host "published v`$Version" -ForegroundColor Green
}

# Restore the version marker to what it was before this session.
function nzRevert {
    `$v = (Get-Content -LiteralPath '$origVer' -Raw).Trim()
    Set-Content -LiteralPath '$verMarker' -Value `$v -NoNewline -Encoding ASCII
    Write-Host "version marker restored -> `$v" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Demo env loaded. Run commands as:  & `$nz check   (or: nz check)' -ForegroundColor Magenta
Write-Host ("  `$nz      = " + `$nz)
Write-Host ("  INST_DIR = " + `$env:INST_DIR)
Write-Host 'Helpers: nzPublish <ver> [-AllowDowngrade] | nzRevert'
"@
Set-Content -LiteralPath $envFile -Value $env_ps1 -Encoding UTF8

# Prism status
$prism = Get-Process -Name 'PrismLauncher', 'prismlauncher' -ErrorAction SilentlyContinue

# ─── Runbook ────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host ' nz REAL-instance harness is READY' -ForegroundColor Green
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host "  instance : $InstancePath"
Write-Host "  version  : $installedVersion (auto-revertable)"
Write-Host "  packwiz  : $safeSha (no-op sync)"
Write-Host "  nz.exe   : $nzExe"
Write-Host "  server   : http://127.0.0.1:$Port  (PID $($proc.Id))  <- only used by the update demo"
if ($prism) { Write-Host "  [warn] Prism is RUNNING — close it before the update demo." -ForegroundColor Yellow }
Write-Host ''
Write-Host ' NOTE: `nz` is NOT on PATH. Use the full exe path shown below.' -ForegroundColor Yellow
Write-Host '       (In production, `setup` bakes this full path into Prism''s' -ForegroundColor DarkGray
Write-Host '        PreLaunch/PostExit hooks — players never type `nz`.)' -ForegroundColor DarkGray
Write-Host ''
Write-Host ' A) SAFE — works right now, no setup needed (auto-detects your instance):' -ForegroundColor Cyan
Write-Host "      & '$nzExe' backup --force     # snapshot your real Xaero maps / configs"
Write-Host "      & '$nzExe' check              # compare vs the PRODUCTION version pointer"
Write-Host ''
Write-Host ' B) UPDATE demo — load the demo env ONCE, then run (real packwiz, no-op):' -ForegroundColor Cyan
Write-Host "   Step 1 (REQUIRED — sets env + helpers for THIS shell):" -ForegroundColor Yellow
Write-Host "      . '$envFile'"
Write-Host '   Step 2:'
Write-Host '      nzPublish 0.4.3               # pretend a new version shipped'
Write-Host "      & `$nz check                   # now BEHIND (exit 1)"
Write-Host "      & `$nz update                  # REAL packwiz sync (no-op) -> marker 0.4.3"
Write-Host '      nzRevert                      # marker back to 0.4.2'
Write-Host ''
Write-Host ' C) Tear down (stops server + restores your version marker):' -ForegroundColor Cyan
Write-Host "      pwsh '$($PSCommandPath)' down"
Write-Host ''
Write-Host ' AVOID `setup` here — use the sandbox (manual-e2e.ps1) for that.' -ForegroundColor Yellow
Write-Host ''

# Convenience: copy the SAFE backup command to the clipboard so you can paste it.
try {
    Set-Clipboard -Value "& '$nzExe' backup --force"
    Write-Host "(copied the backup command to your clipboard — just paste + Enter)" -ForegroundColor DarkGray
} catch { }
