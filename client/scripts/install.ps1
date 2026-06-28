# NegativeZone Minecraft installer (nz client bootstrap)
#
# Player one-liner (first install):
#   irm https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/install.ps1 | iex
#
# What it does:
#   1. Installs Java 17 (Temurin) + Prism Launcher via winget (skips if present).
#   2. Downloads the nz client to %LOCALAPPDATA%\NegativeZone\nz.exe.
#   3. Runs `nz setup` — pulls the modpack from Azure, wires Prism's launch/exit
#      hooks, and drops an "Update Craft to Exile 2" launcher on your Desktop.
#
# No admin rights needed. Re-running is safe: it upgrades in place and
# preserves your worlds, waypoints, and tuned settings.
#
# Test/override env vars (admins only):
#   NEGATIVEZONE_NZ_EXE_URL   - override the nz.exe download URL
#   NEGATIVEZONE_MANIFEST_URL - override the modpack manifest (test channel)
#   NEGATIVEZONE_SKIP_WINGET  - '1' to skip Java/Prism winget installs

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [warn] $msg" -ForegroundColor Yellow }

$DefaultNzExeUrl = 'https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/nz.exe'
$NzExeUrl = if ($env:NEGATIVEZONE_NZ_EXE_URL) { $env:NEGATIVEZONE_NZ_EXE_URL } else { $DefaultNzExeUrl }

Write-Host ''
Write-Host 'NegativeZone Minecraft installer' -ForegroundColor Magenta
Write-Host '--------------------------------'

# ─── 1. Java 17 + Prism Launcher (winget) ────────────────────────────────────
if ($env:NEGATIVEZONE_SKIP_WINGET -eq '1') {
    Write-Warn 'NEGATIVEZONE_SKIP_WINGET=1 - skipping Java/Prism installation.'
} else {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Warn 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
        Write-Warn 'https://apps.microsoft.com/detail/9NBLGGH4NNS1'
    } else {
        Write-Step 'Checking Java 17'
        $java = Get-Command java -ErrorAction SilentlyContinue
        $haveJava17 = $false
        if ($java) {
            # `java -version` prints to STDERR. Under $ErrorActionPreference='Stop',
            # Windows PowerShell 5.1 promotes that native stderr write to a
            # terminating NativeCommandError, so relax the preference locally.
            $verText = ''
            $prevEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $verText = (& java -version 2>&1 | ForEach-Object { "$_" }) -join ' '
            } catch {
                $verText = ''
            } finally {
                $ErrorActionPreference = $prevEap
            }
            if ($verText -match 'version "17\.') { $haveJava17 = $true }
        }
        if ($haveJava17) {
            Write-Ok 'Java 17 already installed.'
        } else {
            Write-Step 'Installing Java 17 (Temurin) via winget'
            winget install --id EclipseAdoptium.Temurin.17.JDK -e --source winget `
                --accept-package-agreements --accept-source-agreements
            Write-Ok 'Java 17 installed.'
        }

        Write-Step 'Checking Prism Launcher'
        $prismInstalled = (winget list --id PrismLauncher.PrismLauncher -e 2>$null |
            Select-String 'PrismLauncher.PrismLauncher')
        if ($prismInstalled) {
            Write-Ok 'Prism Launcher already installed.'
        } else {
            Write-Step 'Installing Prism Launcher via winget'
            winget install --id PrismLauncher.PrismLauncher -e --source winget `
                --accept-package-agreements --accept-source-agreements
            Write-Ok 'Prism Launcher installed.'
        }
    }
}

# ─── 2. Download nz.exe to a stable location ─────────────────────────────────
Write-Step 'Downloading the nz client'
$nzDir = Join-Path $env:LOCALAPPDATA 'NegativeZone'
New-Item -ItemType Directory -Path $nzDir -Force | Out-Null
$nzExe = Join-Path $nzDir 'nz.exe'
if ($NzExeUrl -ne $DefaultNzExeUrl) {
    Write-Warn "Using OVERRIDE nz.exe URL: $NzExeUrl"
}
try {
    Invoke-WebRequest -Uri $NzExeUrl -OutFile $nzExe -UseBasicParsing
    Write-Ok "nz client saved to $nzExe"
} catch {
    throw "Failed to download nz client from $NzExeUrl : $($_.Exception.Message)"
}

# ─── 3. Run the install ──────────────────────────────────────────────────────
Write-Step 'Installing the Craft to Exile 2 modpack'
# NEGATIVEZONE_NONINTERACTIVE lets `nz setup` skip its confirm prompt when this
# bootstrap is piped via `irm | iex` (no TTY). Players just wait ~2 minutes.
$env:NEGATIVEZONE_NONINTERACTIVE = '1'
& $nzExe setup
$rc = $LASTEXITCODE

if ($rc -ne 0) {
    Write-Warn "Setup exited with code $rc. Re-run this installer to retry."
    return
}

Write-Host ''
Write-Host 'Done!' -ForegroundColor Green
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Open Prism Launcher and sign in with your Microsoft account.'
Write-Host '  2. Send the admin your Minecraft Java username so you can be allowlisted.'
Write-Host '  3. Launch "Craft to Exile 2" and add the server: mc.negativezone.cc'
Write-Host ''
Write-Host 'When a new version ships, double-click "Update Craft to Exile 2" on your Desktop.' -ForegroundColor Cyan
Write-Host ''
