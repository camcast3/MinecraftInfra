# NegativeZone Minecraft setup script
#
# Run from PowerShell (no admin needed):
#   irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 | iex
#
# Verify before running: see the GitHub Release notes for SHA-256 + a
# verification one-liner that refuses to run if the file was tampered with.
#   https://github.com/camcast3/MinecraftInfra/releases?q=setup-v
#
# What this does:
#   1. Installs Eclipse Temurin 17 JDK via winget
#   2. Installs Prism Launcher via winget
#   3. Asks for your Minecraft Java username
#   4. Looks up your UUID via the Mojang API and copies it to your clipboard
#   5. Downloads the pre-built Craft to Exile 2 instance from Azure Blob
#      and installs it into Prism (no CurseForge wait — ~2 min vs ~15 min)

$ErrorActionPreference = 'Stop'

# Manifest URL for the pre-built Prism instance. Public-read Azure blob,
# anonymous fetch. The manifest is the single source of truth for the
# current modpack version + zip URL + sha256.
$ModpackManifestUrl = 'https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest.json'

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [warn] $msg" -ForegroundColor Yellow }

# ─── Preflight ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "NegativeZone Minecraft — automated setup" -ForegroundColor Magenta
Write-Host "----------------------------------------"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "winget is not installed on this PC." -ForegroundColor Red
    Write-Host "Install the 'App Installer' from the Microsoft Store, then re-run:" -ForegroundColor Red
    Write-Host "  https://apps.microsoft.com/detail/9NBLGGH4NNS1" -ForegroundColor Red
    exit 1
}

# ─── Install Java 17 ────────────────────────────────────────────────────────
Write-Step "Installing Eclipse Temurin 17 (Java)"
$javaInstalled = winget list --id EclipseAdoptium.Temurin.17.JDK -e --accept-source-agreements 2>$null | Select-String 'EclipseAdoptium.Temurin.17.JDK'
if ($javaInstalled) {
    Write-Ok "Already installed"
} else {
    winget install --id EclipseAdoptium.Temurin.17.JDK -e --source winget --accept-package-agreements --accept-source-agreements
    Write-Ok "Installed"
}

# ─── Install Prism Launcher ─────────────────────────────────────────────────
Write-Step "Installing Prism Launcher"
$prismInstalled = winget list --id PrismLauncher.PrismLauncher -e --accept-source-agreements 2>$null | Select-String 'PrismLauncher.PrismLauncher'
if ($prismInstalled) {
    Write-Ok "Already installed"
} else {
    winget install --id PrismLauncher.PrismLauncher -e --source winget --accept-package-agreements --accept-source-agreements
    Write-Ok "Installed"
}

# ─── Install the Craft to Exile 2 instance from Azure Blob ─────────────────
$prismInstancesDir = Join-Path $env:APPDATA 'PrismLauncher\instances'

Write-Step "Fetching modpack manifest"
try {
    $manifest = Invoke-RestMethod -Uri $ModpackManifestUrl -ErrorAction Stop
} catch {
    Write-Warn "Could not fetch manifest from $ModpackManifestUrl"
    Write-Warn "Skipping modpack install — you'll need to add it manually via Prism -> Add Instance -> CurseForge."
    $manifest = $null
}

if ($manifest) {
    $instanceTarget = Join-Path $prismInstancesDir $manifest.instance
    $existingVersionFile = Join-Path $instanceTarget '.negativezone-version'
    $needsInstall = $true

    if (Test-Path $existingVersionFile) {
        $current = (Get-Content $existingVersionFile -Raw).Trim()
        if ($current -eq $manifest.version) {
            Write-Ok "Modpack '$($manifest.instance)' v$($manifest.version) already installed"
            $needsInstall = $false
        } else {
            Write-Host "    Updating from v$current to v$($manifest.version)" -ForegroundColor Yellow
        }
    }

    if ($needsInstall) {
        $tempZip = Join-Path $env:TEMP $manifest.blob
        Write-Step "Downloading modpack v$($manifest.version) (~$([math]::Round($manifest.sizeBytes / 1MB)) MB)"
        # BITS gives us a progress bar; fall back to Invoke-WebRequest if it fails
        try {
            Start-BitsTransfer -Source $manifest.url -Destination $tempZip -Description "Craft to Exile 2 v$($manifest.version)"
        } catch {
            Invoke-WebRequest -Uri $manifest.url -OutFile $tempZip
        }

        Write-Step "Verifying SHA-256"
        $actualSha = (Get-FileHash $tempZip -Algorithm SHA256).Hash.ToLower()
        $expectedSha = $manifest.sha256.ToLower()
        if ($actualSha -ne $expectedSha) {
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            throw "SHA-256 mismatch! Expected $expectedSha, got $actualSha. Aborting — possible tampering or corrupted download."
        }
        Write-Ok "sha256 verified"

        Write-Step "Installing into Prism"
        if (Test-Path $instanceTarget) {
            Write-Host "    Backing up existing instance to $instanceTarget.bak" -ForegroundColor Yellow
            if (Test-Path "$instanceTarget.bak") { Remove-Item "$instanceTarget.bak" -Recurse -Force }
            Move-Item $instanceTarget "$instanceTarget.bak"
        }
        if (-not (Test-Path $prismInstancesDir)) {
            New-Item -ItemType Directory -Path $prismInstancesDir -Force | Out-Null
        }
        Expand-Archive -Path $tempZip -DestinationPath $prismInstancesDir -Force
        Set-Content -Path (Join-Path $instanceTarget '.negativezone-version') -Value $manifest.version -Encoding UTF8
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Write-Ok "Instance '$($manifest.instance)' ready in Prism"
    }
}

# ─── Look up UUID ───────────────────────────────────────────────────────────
Write-Step "Looking up your Minecraft UUID"
$username = Read-Host "    Enter your Minecraft Java username"
$username = $username.Trim()

if ([string]::IsNullOrWhiteSpace($username)) {
    Write-Host "    No username entered, exiting." -ForegroundColor Red
    exit 1
}

try {
    $response = Invoke-RestMethod -Uri "https://api.mojang.com/users/profiles/minecraft/$username" -ErrorAction Stop
} catch {
    Write-Host ""
    Write-Host "    Could not find a Minecraft Java account with username '$username'." -ForegroundColor Red
    Write-Host "    Double-check the spelling and try again." -ForegroundColor Red
    exit 1
}

$raw = $response.id
$uuid = '{0}-{1}-{2}-{3}-{4}' -f `
    $raw.Substring(0, 8),
    $raw.Substring(8, 4),
    $raw.Substring(12, 4),
    $raw.Substring(16, 4),
    $raw.Substring(20, 12)

$realName = $response.name

$payload = @"
Username: $realName
UUID: $uuid
"@

Write-Host ""
Write-Host "==> Send this to the admin to get allowlisted:" -ForegroundColor Cyan
Write-Host ""
Write-Host $payload -ForegroundColor White
Write-Host ""

try {
    Set-Clipboard -Value $payload
    Write-Ok "Copied to your clipboard — paste it to the admin with Ctrl+V"
} catch {
    Write-Warn "Couldn't copy to clipboard automatically — copy the text above manually"
}

# ─── Next steps ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==> Next steps" -ForegroundColor Cyan
Write-Host "    1. Open Prism Launcher from the Start menu"
Write-Host "    2. Sign in with your Microsoft account"
if ($manifest) {
    Write-Host "    3. Launch the '$($manifest.instance)' instance (already installed)"
} else {
    Write-Host "    3. Add Instance -> CurseForge -> search 'Craft to Exile 2'"
}
Write-Host "    4. Wait to be allowlisted, then connect to: mc.negativezone.cc"
Write-Host ""
Write-Host "Full guide: https://wiki.negativezone.cc/player-onboarding" -ForegroundColor Cyan
Write-Host ""
