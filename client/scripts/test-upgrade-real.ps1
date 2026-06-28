#requires -Version 7.0
<#
.SYNOPSIS
    Drive a REAL `nz setup` modpack upgrade against your live Prism "Craft to
    Exile 2" instance using a LOCALLY-built zip — no Azure egress, no waiting on
    a real publish. Lets you confirm the full upgrade experience (`.bak`, the
    side-by-side "(old)" rollback instance, Prism Latest/Backup groups, hook
    wiring, user-state preservation, post-exit backup) end-to-end in your real
    Prism Launcher.

.DESCRIPTION
    SAFE BY CONSTRUCTION. The "new" 0.4.3 zip is built FROM your current install,
    so the upgraded instance has the identical real mods/config and stays fully
    playable. Your previous install is preserved twice: as `Craft to Exile 2.bak`
    (the rollback target) and as the `Craft to Exile 2 (old)` Prism instance.
    Use `-Action rollback` to restore the pre-upgrade instance, or `-Action clean`
    to remove the temp staging/server.

    Nothing here touches production Azure or the real published manifest — the
    manifest + zip are served from a loopback HTTP server, and `nz setup` is
    pointed at it via NEGATIVEZONE_MANIFEST_URL.

.PARAMETER Action
    run      (default) build the local zip + serve it + run the real upgrade.
    rollback restore the pre-upgrade instance from `Craft to Exile 2.bak`.
    clean    stop the loopback server and remove the temp staging dir.

.PARAMETER Version
    The version to stamp the locally-built zip as (default 0.4.3). Must differ
    from the installed version, or `nz setup` will version-skip the download.

.PARAMETER Port
    Loopback port for the blob server (default 8788).

.EXAMPLE
    pwsh client/scripts/test-upgrade-real.ps1            # upgrade 0.4.2 -> 0.4.3 for real
    # ... open Prism, confirm Latest/Backup groups + (old) instance, launch v0.4.3 ...
    pwsh client/scripts/test-upgrade-real.ps1 -Action rollback   # if you want 0.4.2 back
    pwsh client/scripts/test-upgrade-real.ps1 -Action clean
#>

[CmdletBinding()]
param(
    [ValidateSet('run', 'rollback', 'clean')]
    [string] $Action = 'run',
    [string] $Version = '0.4.3',
    [int]    $Port = 8788
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# client/scripts -> repo root is two levels up.
$repoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$clientDir = Join-Path $repoRoot 'client'

$instanceName = 'Craft to Exile 2'
$prismInstances = Join-Path $env:APPDATA "PrismLauncher\instances"
$instance   = Join-Path $prismInstances $instanceName
$bak        = "$instance.bak"
$old        = Join-Path $prismInstances "$instanceName (old)"

$work     = Join-Path $env:TEMP 'nz-test-upgrade'
$stageInst = Join-Path $work $instanceName        # zipped with includeBaseDirectory
$blobDir  = Join-Path $work 'blob'
$zipPath  = Join-Path $blobDir "c2e2-v$Version.zip"
$pidFile  = Join-Path $work 'server.pid'
$srvExe   = Join-Path $work 'blobserver.exe'

function Write-Head($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "    [ok] $t" -ForegroundColor Green }
function Write-Warn($t) { Write-Host "    [warn] $t" -ForegroundColor Yellow }
function Write-Err($t)  { Write-Host "    [err] $t" -ForegroundColor Red }

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

function Assert-PrismClosed {
    if (Get-Process -Name java, javaw -ErrorAction SilentlyContinue) {
        throw "Minecraft (java) is running. Close the game first."
    }
    if (Get-Process -Name prismlauncher -ErrorAction SilentlyContinue) {
        throw "Prism Launcher is running. Close it completely first (it rewrites instance.cfg on exit)."
    }
}

# ─── clean ───────────────────────────────────────────────────────────────────
if ($Action -eq 'clean') {
    Stop-Server
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok "Removed temp staging + stopped server: $work"
    # Sweep up any post-rollback leftovers ("<instance>.rolledback-<timestamp>")
    # so they don't linger as 1+ GB junk instances in Prism's grid.
    $leftovers = Get-ChildItem -LiteralPath $prismInstances -Directory -Filter "$instanceName.rolledback-*" -ErrorAction SilentlyContinue
    foreach ($lo in $leftovers) {
        Remove-Item -LiteralPath $lo.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed rollback leftover: $($lo.Name)"
    }
    return
}

# ─── rollback ────────────────────────────────────────────────────────────────
if ($Action -eq 'rollback') {
    Assert-PrismClosed
    if (-not (Test-Path -LiteralPath $bak)) {
        throw "No backup found at $bak — nothing to roll back to."
    }
    Write-Head "Rolling back to the pre-upgrade instance"
    if (Test-Path -LiteralPath $instance) {
        $discard = "$instance.rolledback-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Move-Item -LiteralPath $instance -Destination $discard
        Write-Ok "Moved current install aside -> $discard"
    }
    Move-Item -LiteralPath $bak -Destination $instance
    Write-Ok "Restored $instanceName from .bak"
    if (Test-Path -LiteralPath $old) {
        Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed side-by-side '(old)' instance"
    }
    # Clear our groups so Prism shows a single clean instance again.
    $groupsFile = Join-Path $prismInstances 'instgroups.json'
    if (Test-Path -LiteralPath $groupsFile) {
        '{"formatVersion":"1","groups":{}}' |
            Set-Content -LiteralPath $groupsFile -Encoding UTF8 -NoNewline
        Write-Ok "Reset instgroups.json"
    }
    $ver = (Get-Content (Join-Path $instance '.negativezone-version') -Raw -EA SilentlyContinue).Trim()
    Write-Host ''
    Write-Host "Rollback complete. Installed version is now: $ver" -ForegroundColor Green
    Write-Host "The pre-rollback (mock) copy is kept as '$instanceName.rolledback-*' for" -ForegroundColor DarkGray
    Write-Host "inspection. Remove it (and any temp) when happy:" -ForegroundColor DarkGray
    Write-Host "      pwsh client/scripts/test-upgrade-real.ps1 -Action clean" -ForegroundColor DarkGray
    return
}

# ─── run ─────────────────────────────────────────────────────────────────────
Assert-PrismClosed
if (-not (Test-Path -LiteralPath $instance)) {
    throw "No instance at $instance — run a normal install first."
}
$installedVer = (Get-Content (Join-Path $instance '.negativezone-version') -Raw -EA SilentlyContinue).Trim()
if ($installedVer -eq $Version) {
    throw "Installed version is already $Version. Pick a different -Version (setup skips the download when versions match), or roll back first."
}

Stop-Server
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $blobDir, $stageInst -Force | Out-Null

# 1. Build a fresh nz.exe from source so the test exercises the latest code.
Write-Head "Building nz.exe from source"
$nzExe = Join-Path $work 'nz.exe'
Push-Location $clientDir
try {
    & go build -o $nzExe ./cmd/nz/
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
Write-Ok $nzExe

# 2. Stage a copy of the current install as the "new" version. Exclude transient
#    /heavy-but-regenerated dirs so the zip is lean; keep mods/config/etc. so the
#    upgraded instance is genuinely playable.
Write-Head "Staging a local v$Version zip from your current v$installedVer install"
$rc = & robocopy $instance $stageInst /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP `
        /XD logs crash-reports .mixin.out screenshots backups `
        /XF nz.log nz.log.1 2>&1
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)`n$($rc -join "`n")" }

# Bump the staged instance.cfg display name so Prism's grid shows the new version.
$stageCfg = Join-Path $stageInst 'instance.cfg'
if (Test-Path -LiteralPath $stageCfg) {
    $lines = Get-Content -LiteralPath $stageCfg
    $sawName = $false
    $lines = $lines | ForEach-Object {
        if ($_ -match '^name=') { $sawName = $true; "name=$instanceName v$Version" } else { $_ }
    }
    if (-not $sawName) { $lines += "name=$instanceName v$Version" }
    Set-Content -LiteralPath $stageCfg -Value $lines -Encoding UTF8
}
# Ensure a preserve-list exists in the staged .negativezone (setup reads it for
# the new instance's user-state restore scope).
$stageNz = Join-Path $stageInst '.negativezone'
New-Item -ItemType Directory -Path $stageNz -Force | Out-Null

# 3. Zip with the instance folder as the root entry ("Craft to Exile 2/...").
Write-Head "Compressing v$Version zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stageInst, $zipPath,
    [System.IO.Compression.CompressionLevel]::Fastest,
    $true)   # includeBaseDirectory -> root entry is "Craft to Exile 2/"
$sha  = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item -LiteralPath $zipPath).Length
Write-Ok ("zip {0:N1} MB  sha256={1}" -f ($size / 1MB), $sha.Substring(0, 12))

# 4. Manifest (real sha/size so setup's verification passes).
$manifest = [ordered]@{
    version    = $Version
    instance   = $instanceName
    url        = "http://127.0.0.1:$Port/c2e2-v$Version.zip"
    sha256     = $sha
    sizeBytes  = $size
    packwizUrl = "http://127.0.0.1:$Port/pack.toml"
}
[IO.File]::WriteAllText((Join-Path $blobDir 'latest.json'),
    ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
'name = "Craft to Exile 2"' | Set-Content -LiteralPath (Join-Path $blobDir 'pack.toml') -Encoding UTF8

# 5. Compiled static file server (streams the large zip with correct
#    Content-Length, matching what nz's downloadWithProgress expects).
Write-Head "Starting loopback blob server on http://127.0.0.1:$Port"
$srvGo = Join-Path $work 'server.go'
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
Push-Location $clientDir
try {
    & go build -o $srvExe $srvGo
    if ($LASTEXITCODE -ne 0) { throw "server build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
$proc = Start-Process -FilePath $srvExe -ArgumentList @($blobDir, "127.0.0.1:$Port") -WindowStyle Hidden -PassThru
$proc.Id | Set-Content -LiteralPath $pidFile -Encoding ASCII
Start-Sleep -Milliseconds 500
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/latest.json" -UseBasicParsing -TimeoutSec 5
    Write-Ok "server up (PID $($proc.Id))"
} catch {
    Stop-Server
    throw "Blob server failed to start on port $Port. $_"
}

# 6. Run the REAL upgrade against the real Prism instance.
Write-Head "Running nz setup (upgrade $installedVer -> $Version) from the LOCAL zip"
$env:NEGATIVEZONE_MANIFEST_URL   = "http://127.0.0.1:$Port/latest.json"
$env:NEGATIVEZONE_NONINTERACTIVE = '1'
try {
    & $nzExe setup
    $rc = $LASTEXITCODE
} finally {
    Remove-Item Env:\NEGATIVEZONE_MANIFEST_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\NEGATIVEZONE_NONINTERACTIVE -ErrorAction SilentlyContinue
    Stop-Server
}
if ($rc -ne 0) { throw "nz setup exited with code $rc — see the output above. Your .bak is intact for rollback." }

# 7. Verify the upgrade result.
Write-Head "Verifying the upgrade"
$newVer = (Get-Content (Join-Path $instance '.negativezone-version') -Raw -EA SilentlyContinue).Trim()
$groupsFile = Join-Path $prismInstances 'instgroups.json'
$groups = if (Test-Path $groupsFile) { Get-Content $groupsFile -Raw | ConvertFrom-Json } else { $null }
$oldCfgOverride = $false
if (Test-Path (Join-Path $old 'instance.cfg')) {
    $oldCfgOverride = (Select-String -Path (Join-Path $old 'instance.cfg') -Pattern '^OverrideCommands=false' -Quiet)
}
$preHook = (Select-String -Path (Join-Path $instance 'instance.cfg') -Pattern '^PreLaunchCommand=' | Select-Object -First 1).Line
$snap = Get-ChildItem (Join-Path $instance '.negativezone\backups') -Directory -EA SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1

function Check($label, $cond) {
    if ($cond) { Write-Ok $label } else { Write-Err $label; $script:failed = $true }
}
$script:failed = $false
Check "Live instance is now v$Version"                 ($newVer -eq $Version)
Check "Backup (.bak) of previous version exists"        (Test-Path $bak)
Check "Side-by-side '(old)' instance exists"            (Test-Path $old)
Check "'(old)' has launch hooks disabled"               $oldCfgOverride
Check "'Latest' group contains the live instance"       ($groups.groups.Latest.instances -contains $instanceName)
Check "'Backup' group contains the .bak"                ($groups.groups.Backup.instances -contains "$instanceName.bak")
Check "PreLaunch hook uses forward slashes (no mangling)" ($preHook -match 'PreLaunchCommand="\\"[A-Za-z]:/')
Check "A backup snapshot exists"                        ($null -ne $snap)
Check "Upgraded .minecraft has mods"                    ((Get-ChildItem (Join-Path $instance '.minecraft\mods') -File -EA SilentlyContinue).Count -gt 0)

Write-Host ''
if ($failed) {
    Write-Host 'SOME CHECKS FAILED — review above. Roll back with: -Action rollback' -ForegroundColor Red
    exit 1
}
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host " Upgrade test PASSED — v$installedVer -> v$Version on your REAL instance" -ForegroundColor Green
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor DarkGray
Write-Host "  Live (Latest) : $instance  (v$newVer)"
Write-Host "  Backup (.bak) : $bak"
Write-Host "  Rollback copy : $old  (launch hooks disabled)"
if ($snap) { Write-Host "  Backup snap   : $($snap.FullName)" }
Write-Host ''
Write-Host ' Next: open Prism Launcher. You should see the live instance under a' -ForegroundColor Cyan
Write-Host ' "Latest" group, and the .bak + "(old)" under a "Backup" group.' -ForegroundColor Cyan
Write-Host ''
Write-Host " HEADS-UP: this is a MOCK v$Version (ahead of the published pointer), so the" -ForegroundColor Yellow
Write-Host " PreLaunch version check will BLOCK launching it in Prism (it correctly" -ForegroundColor Yellow
Write-Host " refuses a client that's ahead of the server). To launch-test the mock" -ForegroundColor Yellow
Write-Host " anyway, set the bypass in the shell BEFORE starting Prism, then open Prism" -ForegroundColor Yellow
Write-Host " from that same shell so the hook inherits it:" -ForegroundColor Yellow
Write-Host '      $env:NEGATIVEZONE_SKIP_VERSION_CHECK = ''1'' ; & "$env:LOCALAPPDATA\Programs\PrismLauncher\prismlauncher.exe"' -ForegroundColor Gray
Write-Host ''
Write-Host ' When done, restore your real install so it matches production (v0.4.2):' -ForegroundColor Yellow
Write-Host "      pwsh client/scripts/test-upgrade-real.ps1 -Action rollback"
Write-Host "      pwsh client/scripts/test-upgrade-real.ps1 -Action clean"
Write-Host ''
