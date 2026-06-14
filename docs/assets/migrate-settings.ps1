# NegativeZone client settings migrator
#
# Copies client-side settings (keybinds, video options, OptiFine/shader
# settings, JourneyMap + Xaero waypoints, creative hotbars) from an old
# Minecraft instance into a new one. For the (uncommon) case where a
# modpack version upgrade left you without your tuned settings — e.g.
# moving from a backup of C2E2 v0.2.0 onto a freshly installed v0.4.x
# that wasn't installed via setup.ps1 (setup.ps1 already preserves these
# automatically on upgrade via the .negativezone\preserve-list.json union).
#
# servers.dat is deliberately NOT copied: this is a single-server pack
# and the build pipeline writes servers.dat directly so pack-author
# updates (DNS migration, additional backend, etc.) propagate to existing
# players. See packwiz/.user-prefs.txt for the full policy rationale.
#
# Run from PowerShell (no admin needed). With no args the script
# auto-detects Prism / CurseForge instances and lets you pick source +
# destination interactively:
#
#   irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/migrate-settings.ps1 | iex
#
# Or pass explicit paths:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/migrate-settings.ps1))) `
#       -OldInstance 'C:\path\to\old' `
#       -NewInstance 'C:\path\to\new'
#
# Each cut release also publishes a signed copy under
#   https://github.com/camcast3/MinecraftInfra/releases?q=migrate-v
# with a SHA-256 verification one-liner in the release notes.
#
# Behavior:
#   - Preview-then-confirm flow. Nothing is touched until you say 'y'.
#   - Anything overwritten in the destination is first moved to
#     <NewInstance>\_migration-backup-<timestamp>\ so the operation is
#     fully reversible.
#   - Skips items not present in the source (no errors).
#   - Does NOT touch config\, defaultconfigs\, mods\, kubejs\, scripts\,
#     packmenu\, saves\, logs\, crash-reports\. Mod configs MUST be ported
#     manually between modpack versions — schemas change and bulk-copying
#     config\ is the #1 cause of post-update crashes.
#
# PS 5.1 compatible — Windows ships PS 5.1 by default, so no PS 7-only syntax.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $OldInstance,
    [string] $NewInstance
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

# Prism / MultiMC / Modrinth wrap the game files in a .minecraft subfolder;
# CurseForge puts them directly in the instance dir. Auto-detect so callers
# can paste either path.
function Resolve-MinecraftRoot {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Instance path not found: $Path"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $dotMc = Join-Path $resolved '.minecraft'
    if (Test-Path -LiteralPath $dotMc -PathType Container) { return $dotMc }
    return $resolved
}

function Find-CandidateInstances {
    $candidates = @()

    $prism = Join-Path $env:APPDATA 'PrismLauncher\instances'
    if (Test-Path -LiteralPath $prism -PathType Container) {
        Get-ChildItem -LiteralPath $prism -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path -LiteralPath (Join-Path $_.FullName '.minecraft') -PathType Container) {
                $candidates += [pscustomobject]@{
                    Launcher = 'Prism'
                    Name     = $_.Name
                    Path     = $_.FullName
                }
            }
        }
    }

    $cf = Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances'
    if (Test-Path -LiteralPath $cf -PathType Container) {
        Get-ChildItem -LiteralPath $cf -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $candidates += [pscustomobject]@{
                Launcher = 'CurseForge'
                Name     = $_.Name
                Path     = $_.FullName
            }
        }
    }

    return ,$candidates
}

function Read-InstancePath {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [array] $Candidates
    )
    if ($Candidates -and $Candidates.Count -gt 0) {
        Write-Host ''
        Write-Host $Prompt -ForegroundColor Cyan
        for ($i = 0; $i -lt $Candidates.Count; $i++) {
            $c = $Candidates[$i]
            Write-Host ("  [{0}] {1,-10} {2}" -f ($i + 1), $c.Launcher, $c.Name)
            Write-Host ("       {0}" -f $c.Path) -ForegroundColor DarkGray
        }
        Write-Host '  [m]  Type a path manually (or paste a full path right here)'
        while ($true) {
            $choice = Read-Host '  Pick one'
            if ([string]::IsNullOrWhiteSpace($choice)) { continue }
            $choice = $choice.Trim('"').Trim()

            if ($choice -match '^[0-9]+$') {
                $idx = [int]$choice - 1
                if ($idx -ge 0 -and $idx -lt $Candidates.Count) {
                    return $Candidates[$idx].Path
                }
                Write-Host "    Out of range: $choice" -ForegroundColor Red
                continue
            }

            if ($choice -eq 'm' -or $choice -eq 'M') { break }

            # User pasted a path at the picker prompt. Accept it directly
            # instead of silently re-prompting (the original behavior
            # forced people to retype their path immediately after).
            if ($choice -match '[\\/:]' -or $choice -match '^\.') {
                if (Test-Path -LiteralPath $choice -PathType Container) {
                    return $choice
                }
                Write-Host "    Not found: $choice" -ForegroundColor Red
                continue
            }

            Write-Host "    Enter a number from the list, 'm' for manual entry, or paste a full path." -ForegroundColor Red
        }
    }
    while ($true) {
        $p = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            $p = $p.Trim('"').Trim()
            if (Test-Path -LiteralPath $p -PathType Container) {
                return $p
            }
            Write-Host "    Not found: $p" -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host 'NegativeZone Minecraft settings migrator' -ForegroundColor Magenta
Write-Host '----------------------------------------'

$candidates = Find-CandidateInstances

if ([string]::IsNullOrWhiteSpace($OldInstance)) {
    $OldInstance = Read-InstancePath 'Path to your OLD instance (the one with your settings)' $candidates
}
if ([string]::IsNullOrWhiteSpace($NewInstance)) {
    $NewInstance = Read-InstancePath 'Path to your NEW instance (the one to copy settings INTO)' $candidates
}

$old = Resolve-MinecraftRoot -Path $OldInstance
$new = Resolve-MinecraftRoot -Path $NewInstance

if ($old -eq $new) { throw 'Old and new instance resolve to the same folder.' }

# Files copied if present in the old instance. servers.dat / servers.dat_old
# are intentionally excluded; see header comment.
$files = @(
    'options.txt',
    'optionsof.txt',
    'optionsshaders.txt',
    'hotbar.nbt'
)

# Folders copied recursively if present in the old instance.
$folders = @(
    'journeymap',
    'XaeroWaypoints',
    'XaeroWorldMap'
)

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $new "_migration-backup-$timestamp"

Write-Step 'Plan'
Write-Host "  From:   $old"
Write-Host "  To:     $new"
Write-Host "  Backup: $backupDir  (created only if existing files would be overwritten)"
Write-Host ''

$plan = @()
foreach ($f in $files) {
    $src = Join-Path $old $f
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        $plan += [pscustomobject]@{
            Type       = 'File'
            Name       = $f
            Source     = $src
            Overwrites = Test-Path -LiteralPath (Join-Path $new $f)
        }
    }
}
foreach ($d in $folders) {
    $src = Join-Path $old $d
    if (Test-Path -LiteralPath $src -PathType Container) {
        $plan += [pscustomobject]@{
            Type       = 'Folder'
            Name       = $d
            Source     = $src
            Overwrites = Test-Path -LiteralPath (Join-Path $new $d)
        }
    }
}

if (-not $plan) {
    Write-Host ''
    Write-Host 'Nothing to migrate - none of the expected items exist in the old instance.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "Looked for these directly under: $old" -ForegroundColor Cyan
    foreach ($f in $files)   { Write-Host ("  file   $f") }
    foreach ($d in $folders) { Write-Host ("  folder $d") }
    Write-Host ''
    Write-Host "Top-level contents of that folder (first 20 entries):" -ForegroundColor Cyan
    $entries = @(Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue | Select-Object -First 20)
    if ($entries.Count -eq 0) {
        Write-Host '  (folder is empty or unreadable)' -ForegroundColor DarkYellow
    } else {
        foreach ($e in $entries) {
            $tag = if ($e.PSIsContainer) { 'd' } else { 'f' }
            Write-Host ("  [{0}] {1}" -f $tag, $e.Name)
        }
    }
    Write-Host ''
    Write-Host 'Most common causes:' -ForegroundColor Cyan
    Write-Host '  - You pointed at the wrong layer. For Prism the right layer is <instance>\.minecraft\.'
    Write-Host '    Try re-running and pointing directly at the .minecraft folder if you have one.'
    Write-Host '  - The backup truly has no settings (e.g. a fresh extract with no playtime).'
    Write-Host '  - You pointed at a .bak that setup.ps1 made AFTER your settings were already lost.'
    return
}

$plan | Format-Table Type, Name, Overwrites -AutoSize

if (-not $PSCmdlet.ShouldProcess($new, 'Apply migration')) {
    Write-Host 'Dry run (-WhatIf). Re-run without -WhatIf to apply.' -ForegroundColor Yellow
    return
}

$confirm = Read-Host 'Proceed? (y/N)'
if ($confirm -notmatch '^[Yy]') {
    Write-Host 'Aborted.' -ForegroundColor Yellow
    return
}

Write-Step 'Applying'
$backupCreated = $false
foreach ($item in $plan) {
    $dst = Join-Path $new $item.Name
    if (Test-Path -LiteralPath $dst) {
        if (-not $backupCreated) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $backupCreated = $true
        }
        Write-Host ("  backup : {0}" -f $item.Name) -ForegroundColor DarkGray
        Move-Item -LiteralPath $dst -Destination (Join-Path $backupDir $item.Name) -Force
    }
    Write-Host ("  copy   : {0}" -f $item.Name) -ForegroundColor Green
    if ($item.Type -eq 'File') {
        Copy-Item -LiteralPath $item.Source -Destination $dst -Force
    } else {
        Copy-Item -LiteralPath $item.Source -Destination $dst -Recurse -Force
    }
}

Write-Step 'Done'
if ($backupCreated) {
    Write-Host "Overwritten items backed up to: $backupDir"
} else {
    Write-Host 'No existing files were overwritten; no backup needed.'
}
Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host '  1. Launch the new instance and verify keybinds, video settings, waypoints, server list.'
Write-Host '  2. Port mod configs manually from old\config\ -> new\config\ one mod at a time.'
Write-Host '     Bulk-copying config\ between modpack versions can crash the game.'
