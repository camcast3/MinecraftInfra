# NegativeZone Minecraft setup script
#
# Run from PowerShell (no admin needed):
#   irm https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 | iex
#
# SHA-256 verification one-liner: see GitHub Release notes at
#   https://github.com/camcast3/MinecraftInfra/releases?q=setup-v
#
# Admin test-publish override: set $env:NEGATIVEZONE_MANIFEST_URL to point
# at latest-test.json before running. The script prints a loud warning when
# the override is active.

$ErrorActionPreference = 'Stop'

# Manifest URL for the pre-built Prism instance. Public-read Azure blob.
# $env:NEGATIVEZONE_MANIFEST_URL override = admin test-publish channel.
$DefaultManifestUrl = 'https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest.json'
$ModpackManifestUrl = if ($env:NEGATIVEZONE_MANIFEST_URL) {
    $env:NEGATIVEZONE_MANIFEST_URL
} else {
    $DefaultManifestUrl
}

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [warn] $msg" -ForegroundColor Yellow }

# Pulled from main so re-running setup picks up the latest update.ps1 even
# when the player is already on the current modpack version.
$UpdateScriptUrl = 'https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/update.ps1'

# Same backfill rationale as update.ps1 — re-running setup once is how pre-PR 2
# players pick up the periodic snapshot hook on an already-installed instance.
$BackupScriptUrl = 'https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/backup.ps1'

# Encoding-tolerant Pre/Post commands: PS 5.1's `-File` reads .ps1 as the
# system ANSI codepage (CP1252 on US Windows) unless the file has a UTF-8
# BOM, which silently mangles em-dashes inside double-quoted string
# literals (byte 0x94 of the em-dash's UTF-8 encoding reads as a closing
# smart-quote). The `-Command` form below uses .NET's UTF-8 decoder
# explicitly so the script parses correctly regardless of file encoding.
# See publish-prism-pack.ps1's Get-SanitizedInstanceCfg for the full
# quoting-layers explanation (Qt INI -> QProcess::splitCommand -> PS).
# Single-quoted so $INST_DIR survives — Prism substitutes it at launch.
$updateInvoke = '& ([scriptblock]::Create([System.IO.File]::ReadAllText(''$INST_DIR\.negativezone\update.ps1'', [System.Text.Encoding]::UTF8)))'
$backupInvoke = '& ([scriptblock]::Create([System.IO.File]::ReadAllText(''$INST_DIR\.negativezone\backup.ps1'', [System.Text.Encoding]::UTF8)))'
$PreLaunchCommand = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "' + $updateInvoke + '"'
$PostExitCommand  = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "' + $backupInvoke + '"'

# Idempotently wires OverrideCommands=true + the given command line into the
# instance.cfg and downloads the named script into <instanceDir>\.negativezone\.
# Separate from the zip-bundled wiring so already-installed players who skip
# the re-install (because they're on the current version) still pick up both
# hooks by re-running the setup one-liner.
function Set-PrismCommandHook {
    param(
        [Parameter(Mandatory)] [string]$InstanceDir,
        [Parameter(Mandatory)] [ValidateSet('PreLaunchCommand', 'PostExitCommand')] [string]$CommandKey,
        [Parameter(Mandatory)] [string]$CommandValue,
        [Parameter(Mandatory)] [string]$ScriptFilename,
        [Parameter(Mandatory)] [string]$ScriptUrl,
        [Parameter(Mandatory)] [string]$FriendlyName
    )

    $cfgPath = Join-Path $InstanceDir 'instance.cfg'
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Write-Warn "instance.cfg not found at $cfgPath — skipping $CommandKey backfill"
        return
    }

    # Download the hook script before writing the cfg line so a missing script
    # doesn't fail every launch (PreLaunch) or every exit (PostExit). Always
    # re-fetch (overwrite) so re-running setup.ps1 also heals a corrupted /
    # outdated on-disk script — the previous Test-Path skip would have left
    # broken update.ps1 files in place forever (e.g. after the CP1252 em-dash
    # parse-crash regression: players can't auto-update past it because the
    # broken script can't run, so setup.ps1 is the only escape hatch).
    $negDir = Join-Path $InstanceDir '.negativezone'
    $scriptPath = Join-Path $negDir $ScriptFilename
    if (-not (Test-Path $negDir)) {
        New-Item -ItemType Directory -Path $negDir -Force | Out-Null
    }
    try {
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $scriptPath -UseBasicParsing -ErrorAction Stop
        Write-Ok "Downloaded $ScriptFilename to $scriptPath"
    } catch {
        if (Test-Path -LiteralPath $scriptPath) {
            Write-Warn "Could not refresh $ScriptFilename from $ScriptUrl ($($_.Exception.Message)) -- keeping existing copy at $scriptPath."
        } else {
            Write-Warn "Could not download $ScriptFilename from $ScriptUrl — $FriendlyName will NOT be enabled."
            Write-Warn "  Re-run this setup script once you have internet access to enable it."
            return
        }
    }

    $cfgLines = Get-Content -LiteralPath $cfgPath -Encoding UTF8
    $updated = New-Object System.Collections.Generic.List[string]
    $sawOverrideCommands = $false
    $sawCommandKey = $false
    $changed = $false
    foreach ($cfgLine in $cfgLines) {
        if ($cfgLine -match '^OverrideCommands=') {
            $sawOverrideCommands = $true
            if ($cfgLine -ne 'OverrideCommands=true') { $changed = $true }
            $updated.Add('OverrideCommands=true')
        } elseif ($cfgLine -match "^$CommandKey=") {
            $sawCommandKey = $true
            $desired = "$CommandKey=$CommandValue"
            if ($cfgLine -ne $desired) { $changed = $true }
            $updated.Add($desired)
        } else {
            $updated.Add($cfgLine)
        }
    }
    if (-not $sawOverrideCommands) {
        $updated.Add('OverrideCommands=true'); $changed = $true
    }
    if (-not $sawCommandKey) {
        $updated.Add("$CommandKey=$CommandValue"); $changed = $true
    }
    if ($changed) {
        Set-Content -LiteralPath $cfgPath -Value $updated -Encoding UTF8
        Write-Ok "$CommandKey wired up ($FriendlyName enabled)"
    } else {
        Write-Ok "$CommandKey already in place"
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

# Round to nearest GB so a 7.8 GB-reporting "8 GB" stick still passes.
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

# ─── Install Craft to Exile 2 from Azure Blob ──────────────────────────────
$prismInstancesDir = Join-Path $env:APPDATA 'PrismLauncher\instances'

Write-Step "Fetching modpack manifest"
if ($ModpackManifestUrl -ne $DefaultManifestUrl) {
    Write-Warn "Using OVERRIDE manifest URL (test publish mode):"
    Write-Warn "  $ModpackManifestUrl"
    Write-Warn "Unset `$env:NEGATIVEZONE_MANIFEST_URL to switch back to production."
}
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
        $prismRunning = Get-Process -Name 'prismlauncher' -ErrorAction SilentlyContinue
        if ($prismRunning) {
            Write-Host ""
            Write-Host "    Prism Launcher is currently running. Close it before installing." -ForegroundColor Red
            Write-Host "    (Right-click the Prism icon in the system tray / taskbar -> Quit)" -ForegroundColor Red
            Read-Host "    Press Enter once Prism is closed to continue"
        }

        $tempZip = Join-Path $env:TEMP $manifest.blob
        Write-Step "Downloading modpack v$($manifest.version) (~$([math]::Round($manifest.sizeBytes / 1MB)) MB)"
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
        # Extract to temp first so we can validate zip layout before touching
        # the player's instance. Newer zips include a top-level icons/ folder.
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

            # Structural sanity check — refuse to install a zip with no mods.
            # v0.4.0 shipped as a 30 KB empty pack (Get-ChildItem on Linux
            # silently skipped .minecraft/ as a dot-prefix hidden dir), and
            # without this guard setup.ps1 happily installed bare Forge,
            # producing FML handshake errors on every server connect because
            # the server had the full mod set and the client had none.
            $srcModsDir = Join-Path $srcInstance '.minecraft/mods'
            if (-not (Test-Path -LiteralPath $srcModsDir)) {
                throw "Modpack zip is missing '$($manifest.instance)/.minecraft/mods/' — refusing to install (this would launch bare Forge against a modded server). Tell the admin: the published v$($manifest.version) blob looks empty."
            }
            $srcModJars = @(Get-ChildItem -LiteralPath $srcModsDir -Filter '*.jar' -File -Force -ErrorAction SilentlyContinue)
            if ($srcModJars.Count -lt 1) {
                throw "Modpack zip has 0 mod JARs in '$($manifest.instance)/.minecraft/mods/' — refusing to install (this would launch bare Forge against a modded server). Tell the admin: the published v$($manifest.version) blob looks empty."
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

            # Prism stores instance icons globally (%APPDATA%\PrismLauncher\icons),
            # NOT inside the instance folder — without this copy the imported
            # instance shows the default icon.
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

            # Half of installed RAM, capped at 12 GB. C2E2 wiki: 4-8 GB
            # recommended; over-allocation causes GC stalls. Preflight ensures
            # totalGB >= 8 so allocGB >= 4.
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
            # Roll back if we replaced the instance before the failure.
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

    # Re-assert both command hooks every run — including when re-install was
    # skipped (version matched). Lets players who pre-date the auto-update /
    # backup hooks stitch them in by re-running the setup one-liner.
    if (Test-Path -LiteralPath $instanceTarget) {
        Write-Step "Verifying auto-update launch hook"
        Set-PrismCommandHook -InstanceDir $instanceTarget `
            -CommandKey 'PreLaunchCommand' -CommandValue $PreLaunchCommand `
            -ScriptFilename 'update.ps1'   -ScriptUrl $UpdateScriptUrl `
            -FriendlyName 'auto-update enabled on next launch'

        Write-Step "Verifying periodic backup hook"
        Set-PrismCommandHook -InstanceDir $instanceTarget `
            -CommandKey 'PostExitCommand' -CommandValue $PostExitCommand `
            -ScriptFilename 'backup.ps1'  -ScriptUrl $BackupScriptUrl `
            -FriendlyName 'periodic snapshots enabled (every 3 days by default)'
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
