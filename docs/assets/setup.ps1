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

# URL of the player-side update.ps1, used by the defensive PreLaunchCommand
# backfill below. Pulled from main so re-running setup always gets the latest
# update.ps1 even when the player is already on the current modpack version
# (and therefore won't pick up a fresh zip).
$UpdateScriptUrl = 'https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/update.ps1'

# PreLaunchCommand value Prism will run on every launch. Single-quoted so PS
# doesn't expand `$INST_DIR` — Prism does that substitution at launch time.
# Outer double quotes are part of the string Prism parses (QProcess::splitCommand
# respects quoted segments containing spaces, e.g. C:\Users\Jane Doe\...).
$PreLaunchCommand = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INST_DIR\.negativezone\update.ps1"'

# Idempotently writes OverrideCommands=true + PreLaunchCommand=... into the
# given instance.cfg, and downloads update.ps1 into <instanceDir>\.negativezone\
# if it isn't already there. Safe to call multiple times — existing correct
# values are detected and left alone.
#
# Why this exists separately from the bundled-in-zip wiring: the publish flow
# bakes both lines into every new client zip, but already-installed players
# who don't get a fresh zip (because they're already on the current version)
# still need the launch hook so future modpack updates auto-apply. Re-running
# the setup one-liner therefore both reinstalls + backfills the launch wiring.
function Set-PrismPreLaunchHook($instanceDir) {
    $cfgPath = Join-Path $instanceDir 'instance.cfg'
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Write-Warn "instance.cfg not found at $cfgPath — skipping PreLaunchCommand backfill"
        return
    }

    # Make sure the update script is on disk where instance.cfg points to it,
    # before we write the launch hook. If we wrote the hook with no script
    # present Prism would fail-closed every launch and block the game.
    $negDir = Join-Path $instanceDir '.negativezone'
    $updateScriptPath = Join-Path $negDir 'update.ps1'
    if (-not (Test-Path -LiteralPath $updateScriptPath)) {
        if (-not (Test-Path $negDir)) {
            New-Item -ItemType Directory -Path $negDir -Force | Out-Null
        }
        try {
            Invoke-WebRequest -Uri $UpdateScriptUrl -OutFile $updateScriptPath -UseBasicParsing -ErrorAction Stop
            Write-Ok "Downloaded update.ps1 to $updateScriptPath"
        } catch {
            Write-Warn "Could not download update.ps1 from $UpdateScriptUrl — auto-update will NOT be enabled."
            Write-Warn "  Re-run this setup script once you have internet access to enable auto-update."
            return
        }
    }

    $cfgLines = Get-Content -LiteralPath $cfgPath -Encoding UTF8
    $updated = New-Object System.Collections.Generic.List[string]
    $sawOverrideCommands = $false
    $sawPreLaunchCommand = $false
    $changed = $false
    foreach ($cfgLine in $cfgLines) {
        if ($cfgLine -match '^OverrideCommands=') {
            $sawOverrideCommands = $true
            if ($cfgLine -ne 'OverrideCommands=true') { $changed = $true }
            $updated.Add('OverrideCommands=true')
        } elseif ($cfgLine -match '^PreLaunchCommand=') {
            $sawPreLaunchCommand = $true
            $desired = "PreLaunchCommand=$PreLaunchCommand"
            if ($cfgLine -ne $desired) { $changed = $true }
            $updated.Add($desired)
        } else {
            $updated.Add($cfgLine)
        }
    }
    if (-not $sawOverrideCommands) {
        $updated.Add('OverrideCommands=true'); $changed = $true
    }
    if (-not $sawPreLaunchCommand) {
        $updated.Add("PreLaunchCommand=$PreLaunchCommand"); $changed = $true
    }
    if ($changed) {
        Set-Content -LiteralPath $cfgPath -Value $updated -Encoding UTF8
        Write-Ok "PreLaunchCommand wired up (auto-update enabled on next launch)"
    } else {
        Write-Ok "PreLaunchCommand already in place"
    }
}

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

# Detect installed system RAM. Used here as a hard gate (C2E2 needs 8 GB+
# total to leave room for Windows alongside Minecraft) and later to size
# Prism's max heap. Round to nearest GB so a 7.8 GB-reporting "8 GB" stick
# still passes.
$totalGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($totalGB -lt 8) {
    Write-Host ""
    Write-Host "Your PC has ${totalGB} GB of RAM. Craft to Exile 2 needs at least 8 GB total" -ForegroundColor Red
    Write-Host "system RAM (4 GB allocated to Minecraft + 4 GB for Windows). The modpack" -ForegroundColor Red
    Write-Host "will not run reliably on this machine, so setup will not continue." -ForegroundColor Red
    Write-Host ""
    Write-Host "C2E2's official requirements: https://github.com/mahjerion/Craft-to-Exile-2/wiki/Installation" -ForegroundColor Red
    exit 1
}
Write-Ok "${totalGB} GB system RAM detected"

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
    Write-Ok "Latest version: v$($manifest.version) ($($manifest.instance))"
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
        # Bail early if Prism is currently running — overwriting an instance
        # while Prism has it open leaves stale cached state and lock files.
        $prismRunning = Get-Process -Name 'prismlauncher' -ErrorAction SilentlyContinue
        if ($prismRunning) {
            Write-Host ""
            Write-Host "    Prism Launcher is currently running. Close it before installing." -ForegroundColor Red
            Write-Host "    (Right-click the Prism icon in the system tray / taskbar -> Quit)" -ForegroundColor Red
            Read-Host "    Press Enter once Prism is closed to continue"
        }

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
        # Extract to a temp dir first so we can validate the zip layout before
        # touching the player's existing instance. Older zips ship only the
        # <InstanceName>/ folder; newer ones also include a top-level icons/.
        $extractDir = Join-Path $env:TEMP ("negativezone-extract-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        $backupPath = "$instanceTarget.bak"
        $backedUp = $false

        try {
            Expand-Archive -Path $tempZip -DestinationPath $extractDir -Force

            $srcInstance = Join-Path $extractDir $manifest.instance
            $srcInstanceCfg = Join-Path $srcInstance 'instance.cfg'
            if (-not (Test-Path -LiteralPath $srcInstanceCfg)) {
                throw "Modpack zip is missing '$($manifest.instance)/instance.cfg' — refusing to install."
            }

            if (-not (Test-Path $prismInstancesDir)) {
                New-Item -ItemType Directory -Path $prismInstancesDir -Force | Out-Null
            }

            if (Test-Path $instanceTarget) {
                Write-Host "    Backing up existing instance to $backupPath" -ForegroundColor Yellow
                if (Test-Path $backupPath) { Remove-Item $backupPath -Recurse -Force }
                Move-Item $instanceTarget $backupPath
                $backedUp = $true
            }

            Move-Item $srcInstance $instanceTarget

            # Copy any bundled icons to Prism's global icons/ directory. Prism
            # stores instance icons here (not inside the instance folder), so
            # without this step the imported instance shows the default icon.
            $srcIcons = Join-Path $extractDir 'icons'
            if (Test-Path $srcIcons) {
                $prismIconsDir = Join-Path $env:APPDATA 'PrismLauncher\icons'
                if (-not (Test-Path $prismIconsDir)) {
                    New-Item -ItemType Directory -Path $prismIconsDir -Force | Out-Null
                }
                Get-ChildItem -Path $srcIcons -File | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination $prismIconsDir -Force
                }
                Write-Ok "Instance icon installed"
            }

            # Tune Java max-heap to half of the player's installed RAM, capped
            # at 12 GB. C2E2's wiki recommends 4-8 GB and warns that over-
            # allocating causes GC stalls — 12 GB is a generous ceiling for
            # 24+ GB systems. Preflight guaranteed totalGB >= 8 so allocGB >= 4.
            $allocGB = [math]::Min(12, [math]::Floor($totalGB / 2))
            $allocMB = $allocGB * 1024
            $cfgPath = Join-Path $instanceTarget 'instance.cfg'
            $cfgLines = Get-Content -LiteralPath $cfgPath -Encoding UTF8
            $updated = New-Object System.Collections.Generic.List[string]
            $sawMax = $false; $sawOverride = $false
            foreach ($cfgLine in $cfgLines) {
                if ($cfgLine -match '^MaxMemAlloc=')      { $updated.Add("MaxMemAlloc=$allocMB"); $sawMax = $true }
                elseif ($cfgLine -match '^OverrideMemory=') { $updated.Add('OverrideMemory=true'); $sawOverride = $true }
                else                                        { $updated.Add($cfgLine) }
            }
            if (-not $sawMax)      { $updated.Add("MaxMemAlloc=$allocMB") }
            if (-not $sawOverride) { $updated.Add('OverrideMemory=true') }
            Set-Content -LiteralPath $cfgPath -Value $updated -Encoding UTF8
            Write-Ok "Allocated ${allocGB} GB to Minecraft (half of ${totalGB} GB system RAM, capped at 12 GB)"

            Set-Content -Path (Join-Path $instanceTarget '.negativezone-version') -Value $manifest.version -Encoding UTF8
            Write-Ok "Instance '$($manifest.instance)' ready in Prism"
        } catch {
            # Roll back to the prior instance if we replaced it before the
            # failure, so a partial install doesn't leave the player stranded.
            if ($backedUp -and (Test-Path $backupPath) -and -not (Test-Path $instanceTarget)) {
                Write-Host "    Install failed — restoring previous instance from backup" -ForegroundColor Yellow
                Move-Item $backupPath $instanceTarget
            }
            throw
        } finally {
            Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        }
    }

    # Defensive backfill: every run of setup.ps1 re-asserts the PreLaunchCommand
    # wiring on the installed instance, including when we skipped re-install
    # because the version already matched. This is how already-onboarded
    # players who pre-date the auto-update launch hook pick it up — they just
    # re-run the setup one-liner once and the hook gets stitched in.
    if (Test-Path -LiteralPath $instanceTarget) {
        Write-Step "Verifying auto-update launch hook"
        Set-PrismPreLaunchHook -instanceDir $instanceTarget
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
