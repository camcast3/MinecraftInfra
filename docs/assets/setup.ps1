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
# $env:NEGATIVEZONE_UPDATE_SCRIPT_URL override = local-E2E test harness.
$DefaultUpdateScriptUrl = 'https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/update.ps1'
$UpdateScriptUrl = if ($env:NEGATIVEZONE_UPDATE_SCRIPT_URL) {
    $env:NEGATIVEZONE_UPDATE_SCRIPT_URL
} else {
    $DefaultUpdateScriptUrl
}

# Lightweight version-check hook wired into Prism's PreLaunchCommand. Replaces
# the heavyweight auto-update path that used to live in update.ps1 — see
# prelaunch-check.ps1's header for rationale (1 GB downloads with no progress
# UI were unacceptable). update.ps1 is still bundled for the user-run
# `irm .../update.ps1 | iex` flow that prelaunch-check.ps1 directs players to.
# $env:NEGATIVEZONE_PRELAUNCH_CHECK_SCRIPT_URL override = local-E2E harness.
$DefaultPrelaunchCheckScriptUrl = 'https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/prelaunch-check.ps1'
$PrelaunchCheckScriptUrl = if ($env:NEGATIVEZONE_PRELAUNCH_CHECK_SCRIPT_URL) {
    $env:NEGATIVEZONE_PRELAUNCH_CHECK_SCRIPT_URL
} else {
    $DefaultPrelaunchCheckScriptUrl
}

# Same backfill rationale as update.ps1 — re-running setup once is how pre-PR 2
# players pick up the periodic snapshot hook on an already-installed instance.
# $env:NEGATIVEZONE_BACKUP_SCRIPT_URL override = local-E2E test harness.
$DefaultBackupScriptUrl = 'https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/backup.ps1'
$BackupScriptUrl = if ($env:NEGATIVEZONE_BACKUP_SCRIPT_URL) {
    $env:NEGATIVEZONE_BACKUP_SCRIPT_URL
} else {
    $DefaultBackupScriptUrl
}

# NEGATIVEZONE_NONINTERACTIVE=1 skips every blocking Read-Host prompt and the
# Mojang UUID lookup at the end. The E2E test harness sets this so it can run
# unattended; production users never set it and see the normal interactive
# flow. The Prism-running check is also gated on this since the harness uses
# a sandboxed APPDATA that can't collide with a real Prism install.
$NonInteractive = ($env:NEGATIVEZONE_NONINTERACTIVE -eq '1')
# Test-only escape hatch. After ~10 rapid winget invocations the harness
# hits winget's source-update rate limiting and `winget list` hangs for
# minutes. Production users never see this because they run setup.ps1
# at most once or twice per machine. The flag short-circuits BOTH
# "already installed" checks AND the install calls themselves —
# harnesses must arrange for Java + Prism to already exist on disk.
$SkipWinget    = ($env:NEGATIVEZONE_SKIP_WINGET -eq '1')
# Test-only escape hatch for the BITS transfer path. BITS occasionally
# wedges on repeated loopback transfers (the harness fires 10+ in a
# minute against a localhost TcpListener) and Start-BitsTransfer can
# block indefinitely. Setting this forces the plain Invoke-WebRequest
# path, which is fine for harness purposes — production users keep BITS
# for its resume + throttling behaviour on large multi-hundred-MB pulls.
$SkipBits      = ($env:NEGATIVEZONE_SKIP_BITS -eq '1')

# Encoding-tolerant + parse-safe Pre/Post commands. Two layers of defense:
#
# 1. PS 5.1's `-File` reads .ps1 as the system ANSI codepage (CP1252 on US
#    Windows) unless the file has a UTF-8 BOM, which silently mangles em-
#    dashes inside double-quoted string literals. The scriptblock::Create +
#    File.ReadAllText UTF-8 form below decodes the file with .NET's UTF-8
#    decoder explicitly so the script parses correctly regardless of file
#    encoding on disk.
#
# 2. Wrapped in try/catch so a stale or corrupted update.ps1/backup.ps1
#    (missing file, parse error, runtime throw) surfaces a clear "re-run
#    setup.ps1" message in Prism's launch console instead of a stack trace.
#    Without this wrapper the original em-dash parse-crash showed players
#    a wall of PowerShell tokenizer errors with no actionable guidance.
#
# See publish-prism-pack.ps1's Get-SanitizedInstanceCfg for the full
# quoting-layers explanation (Qt INI -> QProcess::splitCommand -> PS).
# Here-strings used because the runtime payload contains many literal
# single quotes — '' escaping inside a single-quoted PS literal would
# make this near-impossible to read or modify.
# $INST_DIR is preserved verbatim — Prism substitutes it at launch time.
$updateInvoke = @'
try { & ([scriptblock]::Create([System.IO.File]::ReadAllText('$INST_DIR\.negativezone\prelaunch-check.ps1', [System.Text.Encoding]::UTF8))) } catch { Write-Host ''; Write-Host '[negativezone] PreLaunch hook failed: your client is out of date or corrupted.'; Write-Host '[negativezone] Re-run the setup one-liner in PowerShell to repair:'; Write-Host '[negativezone]   irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/setup.ps1 | iex'; Write-Host ''; Write-Host ('[negativezone] (underlying error: ' + $_.Exception.Message + ')'); exit 1 }
'@
# PostExit fails OPEN (exit 0) — the player already finished playing, so
# blocking the launcher with a popup adds friction with no recovery benefit.
# Next PreLaunch will surface the same condition loudly and block until fixed.
$backupInvoke = @'
try { & ([scriptblock]::Create([System.IO.File]::ReadAllText('$INST_DIR\.negativezone\backup.ps1', [System.Text.Encoding]::UTF8))) } catch { Write-Host ''; Write-Host '[negativezone] PostExit backup hook failed: your client is out of date or corrupted.'; Write-Host '[negativezone] Re-run the setup one-liner in PowerShell to repair:'; Write-Host '[negativezone]   irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/setup.ps1 | iex'; Write-Host ('[negativezone] (underlying error: ' + $_.Exception.Message + ')'); exit 0 }
'@
$PreLaunchCommand = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "' + $updateInvoke + '"'
$PostExitCommand  = '"powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "' + $backupInvoke + '"'

# ─── Qt INI value escape ────────────────────────────────────────────────────
# Prism stores instance.cfg via Qt's QSettings, which on read processes a
# `\<letter>` escape vocabulary (\\, \", \n, \r, \t, \u####, \x##) and treats
# unwrapped `"..."` segments as quoted runs that get concatenated with the
# whitespace stripped. Our raw PreLaunchCommand is full of literal quotes and
# backslashes (`"powershell.exe" -NoProfile ... '$INST_DIR\.negativezone\update.ps1'`)
# so the very first time Prism saves the cfg back (just clicking Launch
# updates lastLaunchTime, which triggers a full file rewrite) the value gets
# mangled into `"powershell.exe-NoProfile ... $INST_DIRnegativezonepdate.ps1`
# — closing quote + space eaten, `\.` collapsed to `.`, `\u` interpreted as
# the start of a Unicode escape so `update.ps1` becomes `pdate.ps1`. The hook
# then fails to launch with "process failed to start".
#
# Format-QtIniValue emits the canonical Qt escaped form: escape `\` -> `\\`
# and `"` -> `\"`, then wrap the whole value in `"..."`. Qt's reader undoes
# the escapes and Qt's writer re-emits the identical bytes, so the round-trip
# is idempotent and the player's first Launch click no longer corrupts the
# hook. Always wrapping (even when not strictly required) keeps the on-disk
# format predictable across all instance.cfg values we write.
function Format-QtIniValue {
    param([Parameter(Mandatory)][string] $Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

# ─── instgroups.json updater ────────────────────────────────────────────────
# Prism enumerates every <instances>\<dir>\instance.cfg as an instance and
# shows them in a flat list under "Ungrouped" unless instgroups.json assigns
# them to a group. Without grouping, the .bak we leave behind after an
# upgrade shows up alongside the live instance with the same display name —
# confusing players ("which one do I click?"). Same problem appears in the
# unit harness output.
#
# Set-PrismInstanceGroup is the same idempotent, additive pattern as
# Set-PrismCommandHook: preserve any groups the player created themselves,
# strip our managed instances out of every existing group, then assign each
# managed instance to its target group ("Latest" for the live install,
# "Backup" for the previous-version .bak). Skips instances whose folder
# doesn't exist so a missing .bak doesn't leave an empty "Backup" group.
function Set-PrismInstanceGroup {
    param(
        [Parameter(Mandatory)] [string] $InstancesDir,
        [Parameter(Mandatory)] [hashtable] $Assignments
    )
    if (-not (Test-Path -LiteralPath $InstancesDir)) {
        Write-Warn "Instances dir not found at $InstancesDir — skipping group update"
        return
    }
    $groupsFile = Join-Path $InstancesDir 'instgroups.json'

    # Build a set of every instance we're managing so we can strip them out of
    # any previously-existing group before re-assigning. Without this an
    # instance dragged into "Backup" manually would stay in both groups.
    $managed = @{}
    foreach ($g in $Assignments.Keys) {
        foreach ($inst in @($Assignments[$g])) { $managed[$inst] = $true }
    }

    $finalGroups = [ordered]@{}
    if (Test-Path -LiteralPath $groupsFile) {
        try {
            $existing = Get-Content -LiteralPath $groupsFile -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
            if ($existing.groups) {
                foreach ($prop in $existing.groups.PSObject.Properties) {
                    if ($Assignments.ContainsKey($prop.Name)) { continue }
                    $kept = @($prop.Value.instances | Where-Object { -not $managed.ContainsKey($_) })
                    if ($kept.Count -eq 0) { continue }
                    $hiddenVal = $false
                    if ($prop.Value.PSObject.Properties.Match('hidden').Count -gt 0) {
                        $hiddenVal = [bool]$prop.Value.hidden
                    }
                    $finalGroups[$prop.Name] = [pscustomobject]@{
                        hidden    = $hiddenVal
                        instances = $kept
                    }
                }
            }
        } catch {
            Write-Warn "Could not parse $groupsFile ($($_.Exception.Message)) — rewriting from scratch"
        }
    }

    foreach ($g in $Assignments.Keys) {
        $present = @(
            @($Assignments[$g]) | Where-Object { Test-Path -LiteralPath (Join-Path $InstancesDir $_) }
        )
        if ($present.Count -eq 0) { continue }
        $finalGroups[$g] = [pscustomobject]@{
            hidden    = $false
            instances = $present
        }
    }

    $payload = [pscustomobject]@{
        formatVersion = '1'
        groups        = [pscustomobject]$finalGroups
    }
    $json = $payload | ConvertTo-Json -Depth 10
    # Match Prism's stock instgroups.json: BOM-less UTF-8.
    [IO.File]::WriteAllBytes($groupsFile, [Text.UTF8Encoding]::new($false).GetBytes($json))
}

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
    # Qt INI escape — see Format-QtIniValue's comment. Required so Prism's
    # round-trip save doesn't corrupt the value (eating quotes/backslashes
    # and breaking PreLaunch / PostExit).
    $escapedValue = Format-QtIniValue -Value $CommandValue
    foreach ($cfgLine in $cfgLines) {
        if ($cfgLine -match '^OverrideCommands=') {
            $sawOverrideCommands = $true
            if ($cfgLine -ne 'OverrideCommands=true') { $changed = $true }
            $updated.Add('OverrideCommands=true')
        } elseif ($cfgLine -match "^$CommandKey=") {
            $sawCommandKey = $true
            $desired = "$CommandKey=$escapedValue"
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
        $updated.Add("$CommandKey=$escapedValue"); $changed = $true
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
if ($SkipWinget) {
    Write-Ok "Skipped (NEGATIVEZONE_SKIP_WINGET=1; test mode)"
} else {
    $javaInstalled = winget list --id EclipseAdoptium.Temurin.17.JDK -e --accept-source-agreements 2>$null | Select-String 'EclipseAdoptium.Temurin.17.JDK'
    if ($javaInstalled) {
        Write-Ok "Already installed"
    } else {
        winget install --id EclipseAdoptium.Temurin.17.JDK -e --source winget --accept-package-agreements --accept-source-agreements
        Write-Ok "Installed"
    }
}

# ─── Install Prism Launcher ─────────────────────────────────────────────────
Write-Step "Installing Prism Launcher"
if ($SkipWinget) {
    Write-Ok "Skipped (NEGATIVEZONE_SKIP_WINGET=1; test mode)"
} else {
    $prismInstalled = winget list --id PrismLauncher.PrismLauncher -e --accept-source-agreements 2>$null | Select-String 'PrismLauncher.PrismLauncher'
    if ($prismInstalled) {
        Write-Ok "Already installed"
    } else {
        winget install --id PrismLauncher.PrismLauncher -e --source winget --accept-package-agreements --accept-source-agreements
        Write-Ok "Installed"
    }
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
        # Skip install if installed >= manifest, UNLESS the manifest opts
        # into a downgrade. Default-safe: a typo'd manifest version can't
        # silently roll players backward; emergency rollback (publishing
        # an older blob with allowDowngrade:true) still works.
        $allowDowngrade = $false
        if ($manifest.PSObject.Properties.Name -contains 'allowDowngrade') {
            $allowDowngrade = [bool]$manifest.allowDowngrade
        }
        $skipInstall = $false
        try {
            $cv = [version]$current
            $mv = [version]$manifest.version
            if ($cv -eq $mv) {
                $skipInstall = $true
            } elseif ($cv -gt $mv -and -not $allowDowngrade) {
                $skipInstall = $true
            }
        } catch {
            if ($current -eq $manifest.version) { $skipInstall = $true }
        }
        if ($skipInstall) {
            if ($current -eq $manifest.version) {
                Write-Ok "Modpack '$($manifest.instance)' v$($manifest.version) already installed"
            } else {
                Write-Ok "Installed v$current is newer than published v$($manifest.version); not downgrading"
                Write-Host "    Admin must set 'allowDowngrade: true' in the manifest to force a rollback." -ForegroundColor DarkGray
            }
            $needsInstall = $false
        } else {
            if ($allowDowngrade -and ([version]$current -gt [version]$manifest.version)) {
                Write-Host "    Rolling back from v$current to v$($manifest.version) (admin-approved downgrade)" -ForegroundColor Yellow
            } else {
                Write-Host "    Updating from v$current to v$($manifest.version)" -ForegroundColor Yellow
            }
        }
    }

    if ($needsInstall) {
        # In production this guards against overwriting a live Prism install,
        # but the E2E harness writes to a sandboxed APPDATA that has no
        # relationship to whatever Prism the developer might have open.
        if (-not $NonInteractive) {
            $prismRunning = Get-Process -Name 'prismlauncher' -ErrorAction SilentlyContinue
            if ($prismRunning) {
                Write-Host ""
                Write-Host "    Prism Launcher is currently running. Close it before installing." -ForegroundColor Red
                Write-Host "    (Right-click the Prism icon in the system tray / taskbar -> Quit)" -ForegroundColor Red
                Read-Host "    Press Enter once Prism is closed to continue"
            }
        }

        $tempZip = Join-Path $env:TEMP $manifest.blob
        Write-Step "Downloading modpack v$($manifest.version) (~$([math]::Round($manifest.sizeBytes / 1MB)) MB)"
        if ($SkipBits) {
            Invoke-WebRequest -Uri $manifest.url -OutFile $tempZip -UseBasicParsing
        } else {
            try {
                Start-BitsTransfer -Source $manifest.url -Destination $tempZip -Description "Craft to Exile 2 v$($manifest.version)"
            } catch {
                Invoke-WebRequest -Uri $manifest.url -OutFile $tempZip
            }
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
                # Pre-swap curated snapshot via the freshly-extracted backup.ps1
                # (NOT the on-disk one — pre-fix installs have a broken copy).
                # Snapshot lives at $instanceTarget\.negativezone\backups\<ts>\
                # and rides along into $backupPath when we Move-Item below, so
                # the snapshot history is preserved on .bak even if the post-
                # swap restore below somehow misses something.
                #
                # Fail-open: if backup.ps1 errors, log and continue — the full
                # filesystem .bak rename one line down is still the safety net.
                $freshBackupPs1 = Join-Path $srcInstance '.negativezone\backup.ps1'
                if (Test-Path -LiteralPath $freshBackupPs1) {
                    Write-Step "Snapshotting existing instance via backup.ps1 (pre-swap safety)"
                    try {
                        # Use the call operator (not Start-Process) — PowerShell
                        # quotes argv elements correctly here, whereas Start-Process
                        # -ArgumentList silently splits paths containing spaces
                        # (e.g. 'Craft to Exile 2' → truncated at first space).
                        & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                            -File $freshBackupPs1 `
                            -InstanceDir $instanceTarget `
                            -Force
                        $backupExit = $LASTEXITCODE
                        if ($backupExit -eq 0) {
                            Write-Ok "Pre-swap snapshot created in $instanceTarget\.negativezone\backups\"
                        } else {
                            Write-Warn "backup.ps1 exited with code $backupExit. Continuing — .bak rename below is still your safety net."
                        }
                    } catch {
                        Write-Warn "Pre-swap snapshot failed ($($_.Exception.Message)). Continuing — .bak rename below is the fallback."
                    }
                }

                Write-Host "    Backing up existing instance to $backupPath" -ForegroundColor Yellow
                if (Test-Path $backupPath) { Remove-Item $backupPath -Recurse -Force }
                Move-Item $instanceTarget $backupPath
                $backedUp = $true
            }

            Move-Item $srcInstance $instanceTarget

            # Carry player state from .bak into the new install. Without this
            # the fresh instance has zero of the player's worlds, configs, or
            # Xaero map data — they'd have to manually merge from .bak after
            # every modpack drop.
            #
            # The preserve set is the UNION of:
            #   1. The hardcoded $preserveList below — player-state dirs and
            #      vanilla files that don't live in the pack (saves, options.txt,
            #      XaeroWaypoints, etc.). Mirrors update.ps1's $PreserveRelative;
            #      keep in sync when adding entries.
            #   2. The pack-author manifest at $srcInstance\.negativezone\
            #      preserve-list.json — pack-shipped mod configs the player
            #      typically tunes (EMI enable/disable, Embeddium graphics,
            #      Xaero map prefs, mod keybinds, etc.). Source-of-truth is
            #      packwiz/.user-prefs.txt; publish-prism-pack.ps1 bundles it
            #      as JSON. Same union pattern update.ps1 uses on auto-update.
            # Without #2, setup-driven upgrades silently wiped every mod config
            # the player had tuned, even though update.ps1's path preserved them.
            if ($backedUp -and (Test-Path -LiteralPath $backupPath)) {
                Write-Step "Carrying user state from previous instance into new install"
                $preserveList = @(
                    'saves', 'screenshots', 'logs', 'crash-reports', 'local', 'backups',
                    'options.txt', 'optionsof.txt', 'optionsshaders.txt',
                    'hotbar.nbt',
                    'usercache.json', 'usernamecache.json', 'realms_persistence.json',
                    'XaeroWaypoints', 'XaeroWorldMap',
                    'journeymap',
                    'shaderpacks', 'resourcepacks'
                )

                # Union in the pack-author manifest from the freshly-extracted
                # zip. Fail-open: a missing/malformed manifest falls back to
                # the hardcoded list only (matches update.ps1's posture).
                $manifestPath = Join-Path $srcInstance '.negativezone\preserve-list.json'
                if (Test-Path -LiteralPath $manifestPath) {
                    try {
                        $manifestObj = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
                            ConvertFrom-Json -ErrorAction Stop
                        $packAuthor = @()
                        if ($manifestObj.preserve) {
                            $packAuthor = @($manifestObj.preserve | Where-Object { $_ })
                        }
                        if ($packAuthor.Count -gt 0) {
                            $seen = @{}
                            $combined = New-Object System.Collections.Generic.List[string]
                            foreach ($p in @($preserveList) + @($packAuthor)) {
                                $t = ($p -as [string]).Trim()
                                if ($t -and -not $seen.ContainsKey($t)) {
                                    $seen[$t] = $true
                                    [void]$combined.Add($t)
                                }
                            }
                            $preserveList = $combined.ToArray()
                            Write-Ok ("Pack-author preserve-list.json contributes {0} mod-config entries" -f $packAuthor.Count)
                        }
                    } catch {
                        Write-Warn "preserve-list.json malformed ($($_.Exception.Message)); using hardcoded list only."
                    }
                }
                $oldDotMc = Join-Path $backupPath '.minecraft'
                $newDotMc = Join-Path $instanceTarget '.minecraft'
                $restored = 0
                if (Test-Path -LiteralPath $oldDotMc) {
                    if (-not (Test-Path -LiteralPath $newDotMc)) {
                        New-Item -ItemType Directory -Path $newDotMc -Force | Out-Null
                    }
                    foreach ($rel in $preserveList) {
                        $src = Join-Path $oldDotMc $rel
                        if (-not (Test-Path -LiteralPath $src)) { continue }
                        $dst = Join-Path $newDotMc $rel
                        try {
                            if (Test-Path -LiteralPath $dst) {
                                Remove-Item -LiteralPath $dst -Recurse -Force
                            }
                            $parent = Split-Path -Parent $dst
                            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                            }
                            # Copy (not move) so .bak stays a complete snapshot
                            # the player can mine for anything we missed.
                            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
                            $restored++
                        } catch {
                            Write-Warn "Failed to carry over '$rel' ($($_.Exception.Message)). Original is still in $backupPath."
                        }
                    }
                }
                Write-Ok "Restored $restored user-state item(s) from previous instance"

                # Carry over .negativezone\backups\ so the player keeps their
                # snapshot history (including the pre-swap snapshot above) in
                # the live instance instead of stranded in .bak.
                $oldBackupsDir = Join-Path $backupPath '.negativezone\backups'
                if (Test-Path -LiteralPath $oldBackupsDir) {
                    try {
                        $newNzDir = Join-Path $instanceTarget '.negativezone'
                        if (-not (Test-Path -LiteralPath $newNzDir)) {
                            New-Item -ItemType Directory -Path $newNzDir -Force | Out-Null
                        }
                        Copy-Item -LiteralPath $oldBackupsDir -Destination $newNzDir -Recurse -Force
                        Write-Ok "Carried over snapshot history (.negativezone\backups\)"
                    } catch {
                        Write-Warn "Could not carry over snapshot history ($($_.Exception.Message)). Snapshots still in $backupPath."
                    }
                }

                Write-Host ''
                Write-Host '    Your previous instance is preserved at:' -ForegroundColor Cyan
                Write-Host "      $backupPath" -ForegroundColor Cyan
                Write-Host '    If anything is missing from your new install, copy it from there.' -ForegroundColor Cyan
                Write-Host ''
            }

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
            # Bump name= to "<instance> v<version>" so Prism's instance grid
            # shows the new version after upgrade. Without this rewrite the
            # zip's stale name= (e.g. "Craft to Exile 2 v0.4.1") survives the
            # upgrade and both the live install and .bak read identically in
            # the UI — players can't tell which one is current.
            $desiredName = "$($manifest.instance) v$($manifest.version)"
            $cfgPath = Join-Path $instanceTarget 'instance.cfg'
            $cfgLines = Get-Content -LiteralPath $cfgPath -Encoding UTF8
            $updated = New-Object System.Collections.Generic.List[string]
            $sawMax = $false; $sawOverride = $false; $sawName = $false
            foreach ($cfgLine in $cfgLines) {
                if ($cfgLine -match '^MaxMemAlloc=')        { $updated.Add("MaxMemAlloc=$allocMB"); $sawMax = $true }
                elseif ($cfgLine -match '^OverrideMemory=') { $updated.Add('OverrideMemory=true'); $sawOverride = $true }
                elseif ($cfgLine -match '^name=')           { $updated.Add("name=$desiredName"); $sawName = $true }
                else                                        { $updated.Add($cfgLine) }
            }
            if (-not $sawMax)      { $updated.Add("MaxMemAlloc=$allocMB") }
            if (-not $sawOverride) { $updated.Add('OverrideMemory=true') }
            if (-not $sawName)     { $updated.Add("name=$desiredName") }
            Set-Content -LiteralPath $cfgPath -Value $updated -Encoding UTF8
            Write-Ok "Allocated ${allocGB} GB to Minecraft (half of ${totalGB} GB system RAM, capped at 12 GB)"

            Set-Content -Path (Join-Path $instanceTarget '.negativezone-version') -Value $manifest.version -Encoding UTF8
            Write-Ok "Instance '$($manifest.instance)' (v$($manifest.version)) ready in Prism"
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
        Write-Step "Verifying pre-launch version check hook"
        # Bundle update.ps1 too even though it's no longer PreLaunch-invoked —
        # it's the script players run manually via the iex one-liner that
        # prelaunch-check.ps1 points at when an update is required. Keeping
        # it bundled means an offline player can still run it locally without
        # another network round-trip.
        $negDir = Join-Path $instanceTarget '.negativezone'
        if (-not (Test-Path -LiteralPath $negDir)) {
            New-Item -ItemType Directory -Path $negDir -Force | Out-Null
        }
        try {
            Invoke-WebRequest -Uri $UpdateScriptUrl -OutFile (Join-Path $negDir 'update.ps1') -UseBasicParsing -ErrorAction Stop
            Write-Ok "Bundled update.ps1 (user-run by 'irm .../update.ps1 | iex' when prelaunch blocks)"
        } catch {
            Write-Warn "Could not refresh bundled update.ps1 from $UpdateScriptUrl ($($_.Exception.Message)); existing copy (if any) left in place."
        }
        Set-PrismCommandHook -InstanceDir $instanceTarget `
            -CommandKey 'PreLaunchCommand' -CommandValue $PreLaunchCommand `
            -ScriptFilename 'prelaunch-check.ps1' -ScriptUrl $PrelaunchCheckScriptUrl `
            -FriendlyName 'pre-launch version check'

        Write-Step "Verifying periodic backup hook"
        Set-PrismCommandHook -InstanceDir $instanceTarget `
            -CommandKey 'PostExitCommand' -CommandValue $PostExitCommand `
            -ScriptFilename 'backup.ps1'  -ScriptUrl $BackupScriptUrl `
            -FriendlyName 'periodic snapshots enabled (every 3 days by default)'

        # Group the live instance under "Latest" and the previous-version
        # .bak (if any) under "Backup" so Prism's instance grid clearly
        # separates them. Both stay visible so the player can roll back from
        # the UI, but they no longer look like duplicate copies of the same
        # instance under "Ungrouped". Reasserted on every run for self-heal.
        $instName     = Split-Path -Leaf $instanceTarget
        $bakName      = "$instName.bak"
        $assignments  = @{
            'Latest' = @($instName)
            'Backup' = @($bakName)
        }
        Set-PrismInstanceGroup -InstancesDir $prismInstancesDir -Assignments $assignments
        Write-Ok "Prism groups updated ('$instName' -> Latest, '$bakName' -> Backup if present)"
    }
}

# ─── Look up UUID ───────────────────────────────────────────────────────────
if ($NonInteractive) {
    Write-Host ""
    Write-Host "    NEGATIVEZONE_NONINTERACTIVE=1 set — skipping UUID lookup." -ForegroundColor DarkGray
    Write-Host "    (Production users see a prompt here to look up their Minecraft UUID for the allowlist.)"
} else {
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
Write-Host "Full guide: https://wiki.negativezone.cc/setup" -ForegroundColor Cyan
Write-Host ""
