# NegativeZone client auto-update — Prism PreLaunchCommand hook
#
# Bundled into the published Prism instance zip at
# <InstanceName>/.negativezone/update.ps1, invoked by Prism on every launch
# via instance.cfg's OverrideCommands=true + PreLaunchCommand line.
#
# Contract (see docs/updates.md for full detail):
#   - Fail-open on network errors so offline play still works.
#   - Fail-closed on SHA-256 mismatch / structural issues — better to bother
#     the player than ship a corrupted install.
#   - Atomic .minecraft swap with rollback; user state preserved.
#
# PS 5.1 compatible — Windows ships PS 5.1 by default, so no PS 7-only syntax.
# Trusts $env:INST_DIR (Prism injects this via CustomCommands plumbing).
#
# Runtime preserve set is the union of $PreserveRelative (hardcoded
# player-state dirs) and a pack-author manifest bundled at
# <InstanceName>/.negativezone/preserve-list.json. Lets the pack author
# preserve mod-config files (Embeddium, Oculus, Xaero, etc.) on update
# without code changes here.

[CmdletBinding()]
param(
    [string] $InstanceDir = $env:INST_DIR
)

$ErrorActionPreference = 'Stop'
# PS 5.1 has no PSNativeCommandUseErrorActionPreference; native callsites
# below use -EA Stop for terminating errors.

# ─── User-run auto-detect ───────────────────────────────────────────────────
# The PreLaunch path is GONE — prelaunch-check.ps1 replaces it and instructs
# the player to run `irm .../update.ps1 | iex` when the client is stale.
# So when invoked WITHOUT INST_DIR (no Prism wrapper present) we treat it
# as a user-run invocation: auto-detect the standard install path, refuse
# to run while Prism has it locked, and print a friendly banner.
$UserRunMode = [string]::IsNullOrWhiteSpace($InstanceDir)
if ($UserRunMode) {
    Write-Host ''
    Write-Host 'NegativeZone Minecraft client update' -ForegroundColor Magenta
    Write-Host '------------------------------------'

    $candidate = Join-Path $env:APPDATA 'PrismLauncher\instances\Craft to Exile 2'
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        Write-Host ''
        Write-Host "  No Craft to Exile 2 instance found at:" -ForegroundColor Red
        Write-Host "    $candidate" -ForegroundColor Red
        Write-Host ''
        Write-Host "  Run setup first to install the modpack:" -ForegroundColor Yellow
        Write-Host '    irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/setup.ps1 | iex' -ForegroundColor Yellow
        exit 1
    }
    $InstanceDir = $candidate
    Write-Host "  Instance: $InstanceDir" -ForegroundColor DarkGray

    # Prism holds the cfg open and would corrupt our atomic swap if it
    # mutates the instance mid-update. Refuse rather than race.
    $prism = Get-Process -Name 'PrismLauncher','prismlauncher' -ErrorAction SilentlyContinue
    if ($prism) {
        Write-Host ''
        Write-Host "  Prism Launcher is currently running (PID $($prism.Id -join ','))." -ForegroundColor Red
        Write-Host "  Close Prism completely and re-run this update." -ForegroundColor Red
        exit 1
    }
    Write-Host '  Prism is closed, proceeding with update...' -ForegroundColor DarkGray
}

$DefaultManifestUrl = 'https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest.json'
# Test-publish channel override — same env var as setup.ps1; loud WARN logged
# below when active so half-set test sessions are visible in update.log.
$ManifestUrl = if ($env:NEGATIVEZONE_MANIFEST_URL) {
    $env:NEGATIVEZONE_MANIFEST_URL
} else {
    $DefaultManifestUrl
}

# Mirrors publish-prism-pack.ps1's $excludePatterns — restored from
# .minecraft.bak after the swap so player state survives updates.
$PreserveRelative = @(
    'saves',
    'screenshots',
    'logs',
    'crash-reports',
    'local',
    'backups',
    'options.txt',
    'optionsof.txt',
    'optionsshaders.txt',
    'usercache.json',
    'usernamecache.json',
    'realms_persistence.json',
    # Xaero's mini/world map cache + waypoints — multi-GB on heavy explorers
    # and represents real player time investment. Without these in the
    # preserve list, every modpack update wipes the player's navigation
    # history and explored-area cache.
    'XaeroWaypoints',
    'XaeroWorldMap',
    # Player-installed shader/resource packs ride alongside the pack-shipped
    # ones; wiping them on update would force re-installation of personal
    # cosmetic choices that have nothing to do with the modpack itself.
    'shaderpacks',
    'resourcepacks'
)

# Fail-open (exit 0) on missing/invalid INST_DIR — only happens when invoked
# from a wrapper that pre-validated it (the user-run mode above already
# auto-detected and exit-1'd if the install was missing).
if ([string]::IsNullOrWhiteSpace($InstanceDir)) {
    Write-Host '[negativezone-update] INST_DIR not set; skipping auto-update.'
    exit 0
}
if (-not (Test-Path -LiteralPath $InstanceDir -PathType Container)) {
    Write-Host "[negativezone-update] INST_DIR does not exist: $InstanceDir; skipping auto-update."
    exit 0
}

$dotMinecraft  = Join-Path $InstanceDir '.minecraft'
$nzDir         = Join-Path $InstanceDir '.negativezone'
$logPath       = Join-Path $nzDir 'update.log'
$lockPath      = Join-Path $nzDir 'update.lock'
$versionPath   = Join-Path $InstanceDir '.negativezone-version'
$instanceCfg   = Join-Path $InstanceDir 'instance.cfg'
$instanceMmc   = Join-Path $InstanceDir 'mmc-pack.json'

if (-not (Test-Path -LiteralPath $nzDir)) {
    New-Item -ItemType Directory -Path $nzDir -Force | Out-Null
}

# ─── Logging helpers ────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Level, [string]$Message)
    $line = ('{0} [{1}] {2}' -f (Get-Date).ToString('o'), $Level, $Message)
    try {
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {
        # Best-effort: nothing useful to do if even the log write fails.
    }
    Write-Host "[negativezone-update] $Message"
}

# ─── Preserve-list resolution ──────────────────────────────────────────────
# The published zip ships a manifest at <InstanceName>/.negativezone/
# preserve-list.json listing pack-shipped files that the user typically
# tunes (Embeddium graphics, Oculus shaders, Xaero map prefs, etc.). The
# runtime restore set is the union of:
#   1. $PreserveRelative (hardcoded above) — player-state dirs and vanilla
#      files like saves/, options.txt, XaeroWaypoints/, shaderpacks/. These
#      aren't pack-shipped and live entirely in launcher logic.
#   2. The pack-author manifest — pack-shipped files the player tunes.
# Read order: prefer the just-extracted zip's manifest ($extractedManifest,
# passed by the caller), fall back to the live in-instance copy from a
# prior update, fall back to hardcoded-only on missing/malformed. Always
# fail-open so a bad manifest never blocks a launch.
function Get-RuntimePreserveSet {
    param(
        [string[]]$Hardcoded,
        [string]$ExtractedManifestPath,
        [string]$LiveManifestPath
    )

    $packAuthor = @()
    $sourceUsed = $null
    foreach ($candidate in @($ExtractedManifestPath, $LiveManifestPath)) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $obj = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
            if ($obj.preserve) {
                $packAuthor = @($obj.preserve | Where-Object { $_ })
                $sourceUsed = $candidate
                break
            }
        } catch {
            Write-Log 'WARN' ("preserve-list.json malformed at '{0}': {1}" -f $candidate, $_.Exception.Message)
        }
    }
    if ($sourceUsed) {
        Write-Log 'INFO' ("Pack-author preserve list: {0} entries from {1}" -f $packAuthor.Count, $sourceUsed)
    } else {
        Write-Log 'INFO' 'No pack-author preserve list found; using hardcoded list only.'
    }

    # Union, de-duplicate, preserve order. Hardcoded first so player-state
    # dirs are restored before per-file mod configs (matters only if a
    # path collision ever occurred, which it shouldn't).
    $seen = @{}
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($Hardcoded) + @($packAuthor)) {
        $trimmed = ($path -as [string]).Trim()
        if ($trimmed -and -not $seen.ContainsKey($trimmed)) {
            $seen[$trimmed] = $true
            [void]$result.Add($trimmed)
        }
    }
    return ,$result.ToArray()
}

# Prism's double-click-to-launch can spawn PreLaunchCommand twice in quick
# succession; without a lock the two update.ps1 instances would race the
# .minecraft swap and corrupt the install.
function Acquire-UpdateLock {
    param([string]$Path, [int]$StaleSeconds = 300)

    if (Test-Path -LiteralPath $Path) {
        $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
        if ($age.TotalSeconds -gt $StaleSeconds) {
            Write-Log 'WARN' ("Removing stale update.lock (age {0}s)" -f [int]$age.TotalSeconds)
            try { Remove-Item -LiteralPath $Path -Force } catch { return $null }
        } else {
            return $null
        }
    }
    try {
        # CreateNew + FileShare.None is atomic across processes — the second
        # concurrent launcher gets IOException and exits gracefully.
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        return $stream
    } catch {
        return $null
    }
}

$lock = Acquire-UpdateLock -Path $lockPath
if (-not $lock) {
    Write-Log 'INFO' 'Another update.ps1 is running (lock held); skipping this invocation.'
    exit 0
}

# ─── Helpers used inside the main try block ────────────────────────────────
function Download-Zip {
    param([string]$Url, [string]$Destination)

    # BITS for progress/resume; Invoke-WebRequest fallback for Server Core or
    # when BITS service is disabled.
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $Url -Destination $Destination -ErrorAction Stop
            return
        }
    } catch {
        Write-Log 'WARN' ("BITS transfer failed ({0}); falling back to Invoke-WebRequest." -f $_.Exception.Message)
    }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
}

function Move-WithReplace {
    param([string]$Source, [string]$Destination)
    # Move-Item refuses to overwrite directories, so for dirs we delete then move.
    if (Test-Path -LiteralPath $Destination) {
        if ((Get-Item -LiteralPath $Destination).PSIsContainer) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
    }
    $parent = Split-Path -LiteralPath $Destination -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Move-Item -LiteralPath $Source -Destination $Destination -Force
}

# ─── Main update flow ──────────────────────────────────────────────────────
$exitCode = 0
$tempZip = $null
$extractDir = $null
$backupMinecraft = $null

try {
    # Missing version file = treat as "v0", forcing an update.
    $installedVersion = if (Test-Path -LiteralPath $versionPath) {
        (Get-Content -LiteralPath $versionPath -Raw -ErrorAction SilentlyContinue).Trim()
    } else {
        ''
    }
    Write-Log 'INFO' ("Installed version: '{0}'" -f $installedVersion)

    # Loud log line on test-channel override so admin can spot it when
    # debugging.
    if ($ManifestUrl -ne $DefaultManifestUrl) {
        Write-Log 'WARN' ("Using OVERRIDE manifest URL (test publish mode): {0}" -f $ManifestUrl)
    }

    # Fail-open: offline play works.
    $manifest = $null
    try {
        $manifest = Invoke-RestMethod -Uri $ManifestUrl -TimeoutSec 5 -ErrorAction Stop
    } catch {
        Write-Log 'WARN' ("Could not fetch manifest from {0}: {1}. Launching with current install." -f $ManifestUrl, $_.Exception.Message)
        $exitCode = 0
        return
    }

    if (-not $manifest.version) {
        Write-Log 'ERROR' 'Manifest fetched but missing "version" field. Failing closed.'
        $exitCode = 1
        return
    }

    if ($manifest.version -eq $installedVersion) {
        Write-Log 'INFO' ("Already on v{0}; nothing to do." -f $manifest.version)
        $exitCode = 0
        return
    }

    # Don't downgrade unless the manifest explicitly opts in. Without this
    # guard, a typo'd manifest version (or a stale local-test manifest
    # override pointing at an older build) would silently roll the player
    # back and discard their snapshot history. Admins ship intentional
    # rollbacks by setting `"allowDowngrade": true` in the published
    # manifest; players then auto-downgrade on next launch.
    $allowDowngrade = $false
    if ($manifest.PSObject.Properties.Name -contains 'allowDowngrade') {
        $allowDowngrade = [bool]$manifest.allowDowngrade
    }
    if ($installedVersion) {
        try {
            if (([version]$installedVersion) -gt ([version]$manifest.version)) {
                if ($allowDowngrade) {
                    Write-Log 'WARN' ("Manifest opts into downgrade: installed v{0} -> v{1} (admin-approved rollback)." -f $installedVersion, $manifest.version)
                } else {
                    Write-Log 'INFO' ("Installed v{0} is newer than manifest v{1}; refusing to downgrade." -f $installedVersion, $manifest.version)
                    Write-Log 'INFO' "Set 'allowDowngrade: true' in the published manifest if this rollback is intentional."
                    $exitCode = 0
                    return
                }
            }
        } catch {
            # Either side unparseable as [version] — fall through to update path.
        }
    }

    Write-Log 'INFO' ("Updating: {0} -> {1}" -f $installedVersion, $manifest.version)

    # ─── Download + hash verification ──────────────────────────────────────
    $tempZip = Join-Path $env:TEMP ("negativezone-update-{0}.zip" -f $manifest.version)
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }

    Write-Log 'INFO' ("Downloading {0} ({1:N1} MB)" -f $manifest.url, ($manifest.sizeBytes / 1MB))
    try {
        Download-Zip -Url $manifest.url -Destination $tempZip
    } catch {
        Write-Log 'WARN' ("Download failed ({0}); launching with current install." -f $_.Exception.Message)
        $exitCode = 0
        return
    }

    $actualSha = Get-Sha256 -Path $tempZip
    $expectedSha = ($manifest.sha256 -as [string]).ToLower()
    if ($actualSha -ne $expectedSha) {
        # Fail-closed: corrupted/tampered blob must not land on disk.
        Write-Log 'ERROR' ("SHA-256 mismatch! expected={0} actual={1}" -f $expectedSha, $actualSha)
        Write-Log 'ERROR' 'Refusing to install. Re-run setup.ps1 if this persists.'
        $exitCode = 1
        return
    }
    Write-Log 'INFO' ("SHA-256 verified: {0}" -f $actualSha)

    # ─── Extract + structural validation ───────────────────────────────────
    $extractDir = Join-Path $env:TEMP ("negativezone-extract-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $tempZip -DestinationPath $extractDir -Force -ErrorAction Stop
    } catch {
        Write-Log 'ERROR' ("Zip extraction failed: {0}" -f $_.Exception.Message)
        $exitCode = 1
        return
    }

    $instanceFolderName = $manifest.instance
    if ([string]::IsNullOrWhiteSpace($instanceFolderName)) {
        Write-Log 'ERROR' 'Manifest missing "instance" field — cannot locate payload inside zip.'
        $exitCode = 1
        return
    }
    $srcInstance   = Join-Path $extractDir $instanceFolderName
    $srcMinecraft  = Join-Path $srcInstance '.minecraft'
    $srcMmcPack    = Join-Path $srcInstance 'mmc-pack.json'

    if (-not (Test-Path -LiteralPath (Join-Path $srcMinecraft 'mods'))) {
        Write-Log 'ERROR' ("Zip is missing '{0}/.minecraft/mods/' -- refusing to install." -f $instanceFolderName)
        Write-Log 'ERROR' 'This usually means a major modpack restructure. Please re-run setup.ps1 to refresh your install.'
        $exitCode = 1
        return
    }

    # mmc-pack.json change = loader or MC version bumped. Prism already
    # parsed the OLD file earlier this launch, so we CANNOT safely swap it
    # now. Player must close Prism and re-run setup.ps1.
    if ((Test-Path -LiteralPath $srcMmcPack) -and (Test-Path -LiteralPath $instanceMmc)) {
        $currentMmcHash = Get-Sha256 -Path $instanceMmc
        $newMmcHash     = Get-Sha256 -Path $srcMmcPack
        if ($currentMmcHash -ne $newMmcHash) {
            Write-Log 'ERROR' 'mmc-pack.json differs (loader or Minecraft version bumped).'
            Write-Log 'ERROR' 'Prism already loaded the old loader version this launch — cannot safely swap.'
            Write-Log 'ERROR' 'Please close Prism and re-run setup.ps1, then relaunch.'
            $exitCode = 1
            return
        }
    }

    # ─── Pre-swap safety snapshot ──────────────────────────────────────────
    # Invoke backup.ps1 with -Force so update day always has a fresh restore
    # point (independent of the periodic 3-day cadence). Spawned as a child
    # process so its exit() doesn't terminate this script; we wait so the
    # snapshot completes before .minecraft is renamed aside.
    # Failures here are logged but non-fatal — auto-update's own rollback
    # is the primary safety net; this is belt-and-suspenders for cases
    # where the new mod set breaks user state in ways we don't anticipate.
    $backupScript = Join-Path $nzDir 'backup.ps1'
    if (Test-Path -LiteralPath $backupScript) {
        Write-Log 'INFO' 'Running pre-swap safety backup (backup.ps1 -Force)'
        try {
            $bpStdout = [System.IO.Path]::GetTempFileName()
            $bpStderr = [System.IO.Path]::GetTempFileName()
            $bpArgs = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', $backupScript,
                '-InstanceDir', $InstanceDir,
                '-Force'
            )
            $bp = Start-Process -FilePath 'powershell.exe' -ArgumentList $bpArgs -Wait -PassThru -NoNewWindow `
                -RedirectStandardOutput $bpStdout -RedirectStandardError $bpStderr
            if ($bp.ExitCode -ne 0) {
                Write-Log 'WARN' ("Pre-swap backup exited with code {0}; continuing with update." -f $bp.ExitCode)
            }
        } catch {
            Write-Log 'WARN' ("Could not run pre-swap backup: {0}; continuing with update." -f $_.Exception.Message)
        } finally {
            if ($bpStdout) { Remove-Item -LiteralPath $bpStdout -Force -ErrorAction SilentlyContinue }
            if ($bpStderr) { Remove-Item -LiteralPath $bpStderr -Force -ErrorAction SilentlyContinue }
        }
    }

    # ─── Atomic .minecraft swap with rollback ──────────────────────────────
    $backupMinecraft = "$dotMinecraft.bak"
    if (Test-Path -LiteralPath $backupMinecraft) {
        # Leftover from a prior crashed run.
        Write-Log 'WARN' ("Removing leftover backup at {0}" -f $backupMinecraft)
        Remove-Item -LiteralPath $backupMinecraft -Recurse -Force
    }

    if (Test-Path -LiteralPath $dotMinecraft) {
        # Atomic rename on same volume.
        Move-Item -LiteralPath $dotMinecraft -Destination $backupMinecraft -Force
    } else {
        # First-run-without-.minecraft case (shouldn't happen but be safe).
        $backupMinecraft = $null
    }

    try {
        Move-Item -LiteralPath $srcMinecraft -Destination $dotMinecraft -Force

        # Compute the runtime preserve set: hardcoded player-state dirs +
        # the pack-author manifest bundled in the just-extracted zip at
        # <InstanceName>/.negativezone/preserve-list.json. Prefer the
        # extracted manifest (current with this pack version); fall back
        # to whatever was last copied to the live $nzDir.
        $extractedManifest = Join-Path $srcInstance '.negativezone\preserve-list.json'
        $liveManifest      = Join-Path $nzDir 'preserve-list.json'
        $runtimePreserve = Get-RuntimePreserveSet `
            -Hardcoded $PreserveRelative `
            -ExtractedManifestPath $extractedManifest `
            -LiveManifestPath $liveManifest

        # Restore user state via move (not copy): rename-style moves on the
        # same volume are O(1) regardless of saves/ size (can be many GB).
        # Copy would double disk usage + IO with no extra safety since the
        # backup is wiped at the end anyway.
        if ($backupMinecraft -and (Test-Path -LiteralPath $backupMinecraft)) {
            foreach ($rel in $runtimePreserve) {
                $src = Join-Path $backupMinecraft $rel
                $dst = Join-Path $dotMinecraft $rel
                if (Test-Path -LiteralPath $src) {
                    try {
                        Move-WithReplace -Source $src -Destination $dst
                    } catch {
                        Write-Log 'WARN' ("Failed to restore '{0}': {1} (continuing -- your data is still in {2})" -f $rel, $_.Exception.Message, $backupMinecraft)
                    }
                }
            }
        }

        # Sync the pack-author manifest into the live $nzDir so backup.ps1
        # (which doesn't see the extracted zip) can use the same list for
        # its snapshot scope. Best-effort — done after the restore so a
        # failed restore doesn't poison the manifest.
        if (Test-Path -LiteralPath $extractedManifest) {
            try {
                Copy-Item -LiteralPath $extractedManifest -Destination $liveManifest -Force
            } catch {
                Write-Log 'WARN' ("Could not sync preserve-list.json into {0}: {1}" -f $nzDir, $_.Exception.Message)
            }
        }

        # Persist the new version (write failure = same update re-applies
        # every launch; annoying but not destructive).
        Set-Content -LiteralPath $versionPath -Value $manifest.version -Encoding UTF8 -NoNewline

        # Cosmetic: name= shows up in Prism's instance grid one launch later
        # because Prism cached the prior value during this launch's parse.
        if (Test-Path -LiteralPath $instanceCfg) {
            try {
                $cfg = Get-Content -LiteralPath $instanceCfg -Encoding UTF8
                $newLabel = ('{0} v{1}' -f $instanceFolderName, $manifest.version)
                $patched = $cfg | ForEach-Object {
                    if ($_ -match '^name=') { "name=$newLabel" } else { $_ }
                }
                # Preserve CRLF — Prism writes CRLF on Windows and LF causes
                # a noisy first launch.
                Set-Content -LiteralPath $instanceCfg -Value $patched -Encoding UTF8
            } catch {
                Write-Log 'WARN' ("Failed to patch instance.cfg name= line: {0}" -f $_.Exception.Message)
            }
        }

        Write-Log 'INFO' ("Update complete: now on v{0}" -f $manifest.version)
    }
    catch {
        # Roll back to the prior install. $backupMinecraft is the original
        # directory we renamed aside.
        Write-Log 'ERROR' ("Swap failed: {0}" -f $_.Exception.Message)
        Write-Log 'ERROR' $_.ScriptStackTrace
        try {
            if (Test-Path -LiteralPath $dotMinecraft) {
                $abandoned = Join-Path $InstanceDir ('.minecraft.abandoned.' + (Get-Date -Format 'yyyyMMddHHmmss'))
                Move-Item -LiteralPath $dotMinecraft -Destination $abandoned -Force
                Write-Log 'WARN' ("Partial .minecraft preserved at: {0}" -f $abandoned)
            }
            if ($backupMinecraft -and (Test-Path -LiteralPath $backupMinecraft)) {
                Move-Item -LiteralPath $backupMinecraft -Destination $dotMinecraft -Force
                Write-Log 'INFO' 'Rollback complete: previous install restored.'
                $backupMinecraft = $null
            }
        } catch {
            Write-Log 'ERROR' ("Rollback ALSO failed: {0}" -f $_.Exception.Message)
            Write-Log 'ERROR' 'Manual intervention required — see partial install path above.'
        }
        $exitCode = 1
        return
    }

    # ─── Cleanup the backup on success ─────────────────────────────────────
    if ($backupMinecraft -and (Test-Path -LiteralPath $backupMinecraft)) {
        try {
            Remove-Item -LiteralPath $backupMinecraft -Recurse -Force
        } catch {
            Write-Log 'WARN' ("Could not delete backup at {0}: {1} (safe to delete manually)." -f $backupMinecraft, $_.Exception.Message)
        }
    }
}
catch {
    # Fail-closed on unexpected exceptions. update.log + launch log have what
    # we need to diagnose.
    Write-Log 'ERROR' ("Unhandled exception: {0}" -f $_.Exception.Message)
    Write-Log 'ERROR' $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    # Lock dispose MUST come before Remove-Item so the file handle releases first.
    if ($lock) { $lock.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    if ($tempZip)    { Remove-Item -LiteralPath $tempZip    -Force -ErrorAction SilentlyContinue }
    if ($extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
}

exit $exitCode
