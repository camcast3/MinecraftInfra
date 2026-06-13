# NegativeZone client auto-update — Prism PreLaunchCommand hook
#
# Bundled into the published Prism instance zip at:
#   <InstanceName>/.negativezone/update.ps1
#
# Invoked by Prism on every launch via the instance.cfg lines:
#   OverrideCommands=true
#   PreLaunchCommand="powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INST_DIR\.negativezone\update.ps1"
#
# Behavior contract (per docs/player-onboarding.md "Updates" section):
#   - Fail-open on network errors (exit 0, log, let the game launch).
#     Players offline or while Azure Blob is down can still play.
#   - Fail-closed on SHA-256 mismatch or structural issues (exit 1, block
#     launch). Better to bother the player than ship a corrupted install.
#   - Atomic .minecraft/ swap: user state (saves, screenshots, options.txt,
#     etc.) is preserved across the swap. Rollback on any mid-swap failure.
#   - One-launch lag on the version label in instance.cfg's name= line.
#     The on-disk source of truth is .negativezone-version; the label is
#     cosmetic so it's safe to bump in this launch and have Prism show it
#     on the next launch.
#
# PS 5.1 compatible — players install Temurin 17 + Prism via winget but
# Windows ships PS 5.1 by default. Don't add PS 7-only syntax here.
#
# Prism injects these environment variables (and substitutes them in
# the command string) per its CustomCommands plumbing. We trust $env:INST_DIR
# as the source of truth and only fall back to other detection if it's
# missing for some reason.

[CmdletBinding()]
param(
    [string] $InstanceDir = $env:INST_DIR
)

$ErrorActionPreference = 'Stop'
# PS 5.1 doesn't have PSNativeCommandUseErrorActionPreference — native calls
# (Expand-Archive, Get-FileHash, BITS) raise terminating errors via -EA Stop
# at each callsite below.

$DefaultManifestUrl = 'https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest.json'
# Test-publish override: when set, the bundled-into-zip update.ps1 honors
# the same NEGATIVEZONE_MANIFEST_URL env var as setup.ps1. The Prism
# PreLaunchCommand fires update.ps1 in the user's session, so the env var
# only needs to be set in that session for the test-pack auto-update to
# stay on the test channel. Loud warning is logged when the override is in
# use, so a half-set test session is visible in the update.log.
$ManifestUrl = if ($env:NEGATIVEZONE_MANIFEST_URL) {
    $env:NEGATIVEZONE_MANIFEST_URL
} else {
    $DefaultManifestUrl
}

# Files + directories the swap MUST preserve from the player's current
# install. Mirrors publish-prism-pack.ps1's $excludePatterns — anything
# excluded from the published zip needs to be restored from .minecraft.bak
# after the swap, or the player loses user state on every update.
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
    'servers.dat',
    'usercache.json',
    'usernamecache.json',
    'realms_persistence.json'
)

# ─── INST_DIR resolution ────────────────────────────────────────────────────
# Without $InstanceDir we don't know which instance to touch. Fail-open
# (exit 0) so missing variable doesn't block the launch — Prism's launch
# log captures the warning for diagnosis.
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
        # Best-effort: if even the log write fails (disk full?), there's
        # nothing useful we can do beyond also printing to the launch log.
    }
    Write-Host "[negativezone-update] $Message"
}

# ─── Concurrency lock ───────────────────────────────────────────────────────
# Prism allows double-click-to-launch which can spawn the PreLaunchCommand
# twice in quick succession. Without a lock, two concurrent update.ps1
# instances would race the .minecraft swap and corrupt the install.
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
        # CreateNew + FileShare.None makes the open atomic across processes —
        # the second concurrent launcher will get IOException and we return
        # $null so it can exit gracefully (the first one is mid-update).
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

    # BITS gives us progress and resumes; Invoke-WebRequest is the universal
    # fallback (Server Core, BITS service disabled, etc.). Either one ends
    # with the full file at $Destination or throws.
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
    # Replace the destination atomically if it exists. Move-Item refuses to
    # overwrite directories, so for dirs we delete-then-move; for files we
    # let Move-Item with -Force do its job.
    if (Test-Path -LiteralPath $Destination) {
        if ((Get-Item -LiteralPath $Destination).PSIsContainer) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
    }
    # Ensure parent exists for files like servers.dat being restored after
    # the new .minecraft was written empty.
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
    # Detect installed version. Missing file = treat as "v0", forcing an update.
    $installedVersion = if (Test-Path -LiteralPath $versionPath) {
        (Get-Content -LiteralPath $versionPath -Raw -ErrorAction SilentlyContinue).Trim()
    } else {
        ''
    }
    Write-Log 'INFO' ("Installed version: '{0}'" -f $installedVersion)

    # Loud log line when the test manifest override is in use so half-set
    # test sessions are obvious in update.log (which the admin reads when
    # debugging an auto-update issue).
    if ($ManifestUrl -ne $DefaultManifestUrl) {
        Write-Log 'WARN' ("Using OVERRIDE manifest URL (test publish mode): {0}" -f $ManifestUrl)
    }

    # Fetch manifest. Fail-open on any network error so offline play works.
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
        # Hash mismatch is fail-closed: a corrupted download or a tampered
        # blob must not silently land in the player's instance.
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
        Write-Log 'ERROR' ("Zip is missing '{0}/.minecraft/mods/' — refusing to install." -f $instanceFolderName)
        Write-Log 'ERROR' 'This usually means a major modpack restructure. Please re-run setup.ps1 to refresh your install.'
        $exitCode = 1
        return
    }

    # mmc-pack.json change detection — Prism already parsed the OLD file
    # earlier this launch, so we CANNOT safely swap it now. Bail with a
    # clear message; setup.ps1 (run before Prism opens) is the right
    # fix-path because Prism re-reads mmc-pack.json on import.
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

    # ─── Atomic .minecraft swap with rollback ──────────────────────────────
    $backupMinecraft = "$dotMinecraft.bak"
    if (Test-Path -LiteralPath $backupMinecraft) {
        # Leftover from a prior crashed run — clear it so the rename below
        # has a clean target. The current .minecraft is still authoritative.
        Write-Log 'WARN' ("Removing leftover backup at {0}" -f $backupMinecraft)
        Remove-Item -LiteralPath $backupMinecraft -Recurse -Force
    }

    if (Test-Path -LiteralPath $dotMinecraft) {
        # Atomic rename — same volume, instant on Windows.
        Move-Item -LiteralPath $dotMinecraft -Destination $backupMinecraft -Force
    } else {
        # First-run-without-.minecraft case (shouldn't happen but be safe).
        $backupMinecraft = $null
    }

    try {
        # Move the new .minecraft into place.
        Move-Item -LiteralPath $srcMinecraft -Destination $dotMinecraft -Force

        # Preserve user state from the backup. We move (rather than copy)
        # the relative paths from .minecraft.bak into the new .minecraft —
        # rename-style moves on the same volume are O(1) per path regardless
        # of the size of `saves/`, which can be many GB. The plan called for
        # "copy aside, then restore" but move is functionally equivalent
        # since the backup is wiped at the end anyway, and copy doubles the
        # disk usage + IO for no extra safety.
        if ($backupMinecraft -and (Test-Path -LiteralPath $backupMinecraft)) {
            foreach ($rel in $PreserveRelative) {
                $src = Join-Path $backupMinecraft $rel
                $dst = Join-Path $dotMinecraft $rel
                if (Test-Path -LiteralPath $src) {
                    try {
                        Move-WithReplace -Source $src -Destination $dst
                    } catch {
                        Write-Log 'WARN' ("Failed to restore '{0}': {1} (continuing — your data is still in {2})" -f $rel, $_.Exception.Message, $backupMinecraft)
                    }
                }
            }
        }

        # Persist the new version. If this write fails we'd reapply the same
        # update on every launch — annoying but not destructive.
        Set-Content -LiteralPath $versionPath -Value $manifest.version -Encoding UTF8 -NoNewline

        # Update the Prism instance.cfg name= line so the player sees the
        # version in Prism's instance grid. Cosmetic; effective next launch
        # because Prism cached the previous value during this launch's
        # instance.cfg parse.
        if (Test-Path -LiteralPath $instanceCfg) {
            try {
                $cfg = Get-Content -LiteralPath $instanceCfg -Encoding UTF8
                $newLabel = ('{0} v{1}' -f $instanceFolderName, $manifest.version)
                $patched = $cfg | ForEach-Object {
                    if ($_ -match '^name=') { "name=$newLabel" } else { $_ }
                }
                # Preserve CRLF line endings — Prism writes CRLF on Windows
                # and rewriting with LF causes a noisy first launch.
                Set-Content -LiteralPath $instanceCfg -Value $patched -Encoding UTF8
            } catch {
                Write-Log 'WARN' ("Failed to patch instance.cfg name= line: {0}" -f $_.Exception.Message)
            }
        }

        Write-Log 'INFO' ("Update complete: now on v{0}" -f $manifest.version)
    }
    catch {
        # Swap failed — try to roll back to the prior install. We expect the
        # rollback to succeed because $backupMinecraft is the original
        # directory we renamed aside in step 1.
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
    # Any unexpected exception above the inner try-catch: log full trace and
    # fail-closed. Players running Prism via setup.ps1 should never hit this
    # path — if they do, the launch log + update.log have what we need.
    Write-Log 'ERROR' ("Unhandled exception: {0}" -f $_.Exception.Message)
    Write-Log 'ERROR' $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    # Release lock + clean transient artifacts. Lock dispose must come before
    # the Remove-Item so the file handle is released first.
    if ($lock) { $lock.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    if ($tempZip)    { Remove-Item -LiteralPath $tempZip    -Force -ErrorAction SilentlyContinue }
    if ($extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
}

exit $exitCode
