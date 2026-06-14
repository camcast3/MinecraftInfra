# NegativeZone client backup — Prism PostExitCommand hook
#
# Bundled into the published Prism instance zip at:
#   <InstanceName>/.negativezone/backup.ps1
#
# Invoked by Prism after the game exits via instance.cfg:
#   OverrideCommands=true
#   PostExitCommand="powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INST_DIR\.negativezone\backup.ps1"
#
# Also invoked inline with -Force by update.ps1 immediately before the
# .minecraft swap, so every modpack update is guaranteed a fresh snapshot
# even for players who close Prism unusually (Task Manager kill, host crash).
#
# Behavior:
#   - Fast-path skip if newest snapshot is younger than NEGATIVEZONE_BACKUP_DAYS
#     (default 3). PostExitCommand blocks Prism's "stopped" UI state, so we
#     bail in <100ms on the typical exit.
#   - Snapshot a curated allow-list of user-state dirs/files into
#     <InstanceDir>\.negativezone\backups\<yyyyMMdd-HHmmss>\ using robocopy.
#     Lean default scope (Xaero, shaderpacks, resourcepacks, options,
#     bookmarks, servers.dat); set NEGATIVEZONE_BACKUP_INCLUDE_SAVES=1 to
#     also snapshot .minecraft\saves\ (multi-GB for heavy SP play).
#   - Prune to NEGATIVEZONE_BACKUP_RETAIN newest (default 3). Snapshot dirs
#     are named by sortable timestamp so prune is a simple lexicographic tail.
#   - Fail-open: never crash Prism's exit handling. Errors are logged to
#     .negativezone\backup.log; the script always exits 0 from PostExit.
#
# Manual restore:
#   Each snapshot is a self-contained tree of files mirroring their original
#   layout under .minecraft\. Copy the dirs/files back into .minecraft\ with
#   Prism closed to restore. See docs/backups.md for the runbook.
#
# PS 5.1 compatible — players install Temurin 17 + Prism via winget but
# Windows ships PS 5.1 by default. Don't add PS 7-only syntax here.

[CmdletBinding()]
param(
    [string] $InstanceDir = $env:INST_DIR,
    # update.ps1 passes -Force so the pre-swap snapshot bypasses the cadence
    # skip — update day is exactly when we want a fresh restore point.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# ─── Scope ──────────────────────────────────────────────────────────────────
# Directories backed up wholesale. XaeroWorldMap is the dominant size term
# (multi-GB on heavy explorers) and the main reason this script exists —
# losing a year's worth of explored map cache to a modpack update is the
# single most-painful state-loss scenario for C2E2.
$DirectoryItems = @(
    'XaeroWaypoints'
    'XaeroWorldMap'
    # JourneyMap data — same rationale as XaeroWorldMap (waypoints + tile
    # cache, multi-GB on heavy explorers). C2E2's waystones mod writes
    # waypoints here when displayWaystonesOnJourneyMap is enabled.
    'journeymap'
    'screenshots'
    'shaderpacks'
    'resourcepacks'
    'config/jei'
    'config/emi'
)

# Individual files. servers.dat is small but critical — losing the server
# list entry is annoying. options* files capture keybinds + video settings.
# hotbar.nbt is vanilla creative-mode hotbar saves (tiny).
$FileItems = @(
    'options.txt'
    'optionsof.txt'
    'optionsshaders.txt'
    'hotbar.nbt'
    'servers.dat'
    'usercache.json'
    'usernamecache.json'
)

# ─── INST_DIR resolution ────────────────────────────────────────────────────
# Mirror update.ps1's fail-open posture — a missing INST_DIR shouldn't be a
# fatal exit on the PostExit hook either (Prism would log a "PostExit failed"
# warning but the game already closed cleanly, so it's user-visible noise).
if ([string]::IsNullOrWhiteSpace($InstanceDir)) {
    Write-Host '[negativezone-backup] INST_DIR not set; skipping backup.'
    exit 0
}
if (-not (Test-Path -LiteralPath $InstanceDir -PathType Container)) {
    Write-Host "[negativezone-backup] INST_DIR does not exist: $InstanceDir; skipping backup."
    exit 0
}

# Opt-out switch — players who can't tolerate the disk footprint or just want
# Prism's exit to be instantaneous can set NEGATIVEZONE_BACKUP_DISABLE=1 in
# their user environment without touching instance.cfg.
if ($env:NEGATIVEZONE_BACKUP_DISABLE -eq '1') {
    Write-Host '[negativezone-backup] NEGATIVEZONE_BACKUP_DISABLE=1; skipping backup.'
    exit 0
}

$dotMinecraft = Join-Path $InstanceDir '.minecraft'
$nzDir        = Join-Path $InstanceDir '.negativezone'
$backupsDir   = Join-Path $nzDir 'backups'
$logPath      = Join-Path $nzDir 'backup.log'
$lockPath     = Join-Path $nzDir 'backup.lock'

if (-not (Test-Path -LiteralPath $dotMinecraft -PathType Container)) {
    Write-Host '[negativezone-backup] .minecraft missing; nothing to back up.'
    exit 0
}
if (-not (Test-Path -LiteralPath $nzDir)) {
    New-Item -ItemType Directory -Path $nzDir -Force | Out-Null
}

# ─── Logging ────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Level, [string]$Message)
    $line = ('{0} [{1}] {2}' -f (Get-Date).ToString('o'), $Level, $Message)
    try {
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {
        # Best-effort: if even the log write fails (disk full?), there's
        # nothing useful we can do beyond also printing to the launch log.
    }
    Write-Host "[negativezone-backup] $Message"
}

# ─── Config parsing ─────────────────────────────────────────────────────────
function Get-IntEnv {
    param([string]$Name, [int]$Default, [int]$Min = 0, [int]$Max = [int]::MaxValue)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value)) {
        Write-Log 'WARN' ("Invalid integer for {0}='{1}'; using default {2}." -f $Name, $raw, $Default)
        return $Default
    }
    if ($value -lt $Min) { return $Min }
    if ($value -gt $Max) { return $Max }
    return $value
}

# Tight upper bounds so a typo (e.g. NEGATIVEZONE_BACKUP_RETAIN=10000) can't
# silently fill the player's disk.
$intervalDays = Get-IntEnv 'NEGATIVEZONE_BACKUP_DAYS'   3 -Min 0 -Max 90
$retainCount  = Get-IntEnv 'NEGATIVEZONE_BACKUP_RETAIN' 3 -Min 1 -Max 50

if ($env:NEGATIVEZONE_BACKUP_INCLUDE_SAVES -eq '1') {
    $DirectoryItems += 'saves'
}

# ─── Extend file scope from pack-author manifest ────────────────────────────
# update.ps1 syncs <InstanceDir>/.negativezone/preserve-list.json on each
# pack update (sourced from packwiz/.user-prefs.txt at publish time). It
# lists pack-shipped files that players typically tune (Embeddium graphics,
# Oculus shaders, Xaero map style, etc.). Because the update.ps1 swap now
# *preserves* these files across updates, our snapshot is the only thing
# protecting them from accidental deletion. Append them to $FileItems so
# every snapshot includes them.
$preserveManifest = Join-Path $nzDir 'preserve-list.json'
if (Test-Path -LiteralPath $preserveManifest) {
    try {
        $obj = Get-Content -LiteralPath $preserveManifest -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
        if ($obj.preserve) {
            $added = 0
            foreach ($rel in @($obj.preserve)) {
                $trimmed = ($rel -as [string]).Trim()
                if ($trimmed -and ($FileItems -notcontains $trimmed)) {
                    $FileItems += $trimmed
                    $added++
                }
            }
            if ($added -gt 0) {
                Write-Log 'INFO' ("Added {0} pack-author file(s) to snapshot scope from {1}" -f $added, $preserveManifest)
            }
        }
    } catch {
        Write-Log 'WARN' ("preserve-list.json malformed; snapshot scope unchanged: {0}" -f $_.Exception.Message)
    }
}

# ─── Skip if recent ─────────────────────────────────────────────────────────
# intervalDays=0 effectively means "back up on every exit" — useful for
# testing the script itself. -Force from update.ps1 also bypasses this so
# update day is always snapshotted.
$timestampRegex = '^\d{8}-\d{6}(-\d+)?$'
if (-not $Force -and $intervalDays -gt 0 -and (Test-Path -LiteralPath $backupsDir)) {
    $newest = Get-ChildItem -LiteralPath $backupsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $timestampRegex } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($newest) {
        $age = (Get-Date) - $newest.CreationTime
        if ($age.TotalDays -lt $intervalDays) {
            $remaining = $intervalDays - $age.TotalDays
            Write-Host ("[negativezone-backup] Last backup {0:N1} day(s) ago; next due in {1:N1} day(s)." -f $age.TotalDays, $remaining)
            exit 0
        }
    }
}

# ─── Concurrency lock ───────────────────────────────────────────────────────
# update.ps1's pre-swap call runs while the player is still at the Prism
# launch screen, and Prism's PostExitCommand fires after the previous game
# session exits. In rare cases (admin closes game, immediately relaunches
# before the post-exit snapshot finishes) these can overlap. Lock keeps them
# serial; the second invocation no-ops instead of racing the filesystem.
function Acquire-BackupLock {
    param([string]$Path, [int]$StaleSeconds = 1800)

    if (Test-Path -LiteralPath $Path) {
        $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
        if ($age.TotalSeconds -gt $StaleSeconds) {
            Write-Log 'WARN' ("Removing stale backup.lock (age {0}s)" -f [int]$age.TotalSeconds)
            try { Remove-Item -LiteralPath $Path -Force } catch { return $null }
        } else {
            return $null
        }
    }
    try {
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

$lock = Acquire-BackupLock -Path $lockPath
if (-not $lock) {
    Write-Log 'INFO' 'Another backup.ps1 is running (lock held); skipping.'
    exit 0
}

# ─── Run backup ─────────────────────────────────────────────────────────────
$exitCode = 0
$snapshotDir = $null
$snapshotCreated = $false

try {
    if (-not (Test-Path -LiteralPath $backupsDir)) {
        New-Item -ItemType Directory -Path $backupsDir -Force | Out-Null
    }

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $snapshotDir = Join-Path $backupsDir $timestamp
    if (Test-Path -LiteralPath $snapshotDir) {
        # Sub-second collision (pre-swap call followed by immediate re-run)
        # is rare but possible — suffix with a random number to make the
        # path unique while keeping the timestamp prefix sortable.
        $snapshotDir = "$snapshotDir-$(Get-Random -Maximum 999)"
    }
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    $snapshotCreated = $true

    Write-Log 'INFO' ("Starting backup -> {0}" -f $snapshotDir)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $copiedAny = $false

    # ─── Directories ────────────────────────────────────────────────────
    # robocopy beats Copy-Item -Recurse on the Xaero map cache by 5-10x.
    # /MIR is safe because we mirror into a fresh empty timestamp dir each
    # snapshot — no risk of nuking existing user data. /MT:8 enables 8-thread
    # copy; /R:1 /W:1 retries once with a 1s wait so we don't stall on a
    # transient lock; /NP /NFL /NDL /NJH /NJS minimize output (Prism's
    # PostExit captures stdout into the launch log, so quieter is better).
    # Exit codes 0-7 are non-fatal; 8+ is a real error.
    #
    # We invoke robocopy via PowerShell's call operator (`&`) rather than
    # `Start-Process -ArgumentList`. In Windows PowerShell 5.1 — which is
    # what Prism's PostExit shells out to — Start-Process does NOT quote
    # array elements that contain spaces, so a path like
    # 'C:\...\Craft to Exile 2\.minecraft\shaderpacks' gets split into four
    # separate argv entries and robocopy fails with exit 16 "Invalid
    # Parameter". The call operator hands each arg through the Win32
    # CreateProcess path with proper escaping, so spaces survive.
    foreach ($rel in $DirectoryItems) {
        $src = Join-Path $dotMinecraft $rel
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }
        $dst = Join-Path $snapshotDir $rel
        # [IO.Path]::GetDirectoryName works on both PS 5.1 and PS 7 — the
        # `Split-Path -LiteralPath -Parent` form has a parameter-set conflict
        # in PS 7 that makes local testing fail even though Prism launches
        # the real script via powershell.exe (PS 5.1) where it would work.
        $parent = [System.IO.Path]::GetDirectoryName($dst)
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        try {
            $robocopyOutput = & robocopy $src $dst /MIR /MT:8 /R:1 /W:1 /NP /NFL /NDL /NJH /NJS 2>&1
            $rc = $LASTEXITCODE
            if ($rc -ge 8) {
                $tail = ($robocopyOutput | Select-Object -Last 3 | Out-String).Trim()
                if ($tail) {
                    Write-Log 'WARN' ("robocopy '{0}' failed (exit {1}); skipping. {2}" -f $rel, $rc, $tail)
                } else {
                    Write-Log 'WARN' ("robocopy '{0}' failed (exit {1}); skipping." -f $rel, $rc)
                }
            } else {
                $copiedAny = $true
            }
        } catch {
            Write-Log 'WARN' ("Could not back up '{0}': {1}" -f $rel, $_.Exception.Message)
        }
    }

    # ─── Files ──────────────────────────────────────────────────────────
    foreach ($rel in $FileItems) {
        $src = Join-Path $dotMinecraft $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $snapshotDir $rel
        $parent = [System.IO.Path]::GetDirectoryName($dst)
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        try {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            $copiedAny = $true
        } catch {
            Write-Log 'WARN' ("Could not back up file '{0}': {1}" -f $rel, $_.Exception.Message)
        }
    }

    $sw.Stop()

    if (-not $copiedAny) {
        Write-Log 'INFO' 'No items matched scope; removing empty snapshot.'
        Remove-Item -LiteralPath $snapshotDir -Recurse -Force -ErrorAction SilentlyContinue
        $snapshotCreated = $false
    } else {
        $sizeMb = 0
        try {
            $sum = (Get-ChildItem -LiteralPath $snapshotDir -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum
            if ($sum) { $sizeMb = $sum / 1MB }
        } catch {
            # Size is for log decoration only; carry on with $sizeMb=0.
        }
        Write-Log 'INFO' ("Backup complete in {0:N1}s, {1:N1} MB at {2}" -f $sw.Elapsed.TotalSeconds, $sizeMb, $snapshotDir)
    }

    # ─── Prune ──────────────────────────────────────────────────────────
    # Lexicographic sort on yyyyMMdd-HHmmss is equivalent to chronological
    # sort, so "skip $retainCount from the top" = "keep newest N, prune rest".
    $all = Get-ChildItem -LiteralPath $backupsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $timestampRegex } |
        Sort-Object Name -Descending
    if ($all.Count -gt $retainCount) {
        $toPrune = $all | Select-Object -Skip $retainCount
        foreach ($old in $toPrune) {
            try {
                Remove-Item -LiteralPath $old.FullName -Recurse -Force
                Write-Log 'INFO' ("Pruned old backup: {0}" -f $old.Name)
            } catch {
                Write-Log 'WARN' ("Could not prune '{0}': {1}" -f $old.FullName, $_.Exception.Message)
            }
        }
    }
}
catch {
    Write-Log 'ERROR' ("Unhandled exception: {0}" -f $_.Exception.Message)
    Write-Log 'ERROR' $_.ScriptStackTrace
    # Try to remove the partial snapshot so it isn't counted as "newest"
    # on the next run (which would push the next real backup out by 3 days).
    if ($snapshotCreated -and $snapshotDir -and (Test-Path -LiteralPath $snapshotDir)) {
        try {
            Remove-Item -LiteralPath $snapshotDir -Recurse -Force
        } catch {
            # Best-effort cleanup — we're already in the outer error handler.
        }
    }
    # Fail-open: never block Prism's exit handling.
    $exitCode = 0
}
finally {
    if ($lock) { $lock.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}

exit $exitCode
