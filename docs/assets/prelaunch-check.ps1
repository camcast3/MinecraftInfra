# NegativeZone client version check - Prism PreLaunchCommand hook
#
# Lightweight (~1 second) check that runs on every launch. Compares the
# installed modpack version against a tiny GitHub-hosted pointer file and
# HARD BLOCKS the launch when the client is out of date so a player can't
# join the server with a mismatched modpack (FML handshake failure).
#
# Why not auto-update inline?
#   The previous PreLaunch hook (update.ps1) downloaded a ~1 GB zip on every
#   version change with no progress UI - Prism just sat showing "Running
#   pre-launch command" for several minutes. Auto-update is now an explicit
#   user-run path; PreLaunch's only job is to gate the launch on freshness.
#
# Cost / privacy:
#   Single ~10-byte GET to raw.githubusercontent.com per launch. GitHub's CDN
#   caches it so we don't hit Azure egress for every player launch and we
#   don't depend on the modpack blob being warm in Hot tier (the lifecycle
#   policy will tier old blobs to Cool after 14 days).
#
# Fail-open conditions (exit 0, allow launch):
#   - INST_DIR unset / missing (mirrors update.ps1)
#   - Version pointer fetch fails (offline play stays usable)
#   - Installed version >= latest version (already current OR ahead - the
#     downgrade-guard scenario where allowDowngrade-less rollback is refused)
#   - Either version unparseable as a [version]
#   - $env:NEGATIVEZONE_SKIP_VERSION_CHECK = '1' bypass set
#
# Fail-closed (exit 1, block launch):
#   - Installed version < latest version  ->  prints update instructions

[CmdletBinding()]
param(
    [string] $InstanceDir = $env:INST_DIR
)

$ErrorActionPreference = 'Stop'

$DefaultLatestVersionUrl = 'https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/latest-version.txt'
# Test harness override - same pattern as $env:NEGATIVEZONE_MANIFEST_URL in
# setup.ps1 / update.ps1. Loud WARN logged below when active so half-set
# test sessions are visible.
$LatestVersionUrl = if ($env:NEGATIVEZONE_LATEST_VERSION_URL) {
    $env:NEGATIVEZONE_LATEST_VERSION_URL
} else {
    $DefaultLatestVersionUrl
}

# User-facing one-liner. Hosted same way as setup.ps1 - the player runs it
# from a separate PowerShell window when they see the block message.
$UpdateOneLiner = 'irm https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/docs/assets/update.ps1 | iex'
$WikiUrl        = 'https://wiki.negativezone.cc/updating'

function Write-Note($msg) { Write-Host "[negativezone] $msg" }

# ─── Bypass + INST_DIR sanity ───────────────────────────────────────────────
if ($env:NEGATIVEZONE_SKIP_VERSION_CHECK -eq '1') {
    Write-Note 'NEGATIVEZONE_SKIP_VERSION_CHECK=1 set; skipping version check.'
    exit 0
}
if ([string]::IsNullOrWhiteSpace($InstanceDir)) {
    Write-Note 'INST_DIR not set; skipping version check.'
    exit 0
}
if (-not (Test-Path -LiteralPath $InstanceDir -PathType Container)) {
    Write-Note "INST_DIR does not exist: $InstanceDir; skipping version check."
    exit 0
}

$versionPath = Join-Path $InstanceDir '.negativezone-version'
$installedVersion = if (Test-Path -LiteralPath $versionPath) {
    (Get-Content -LiteralPath $versionPath -Raw -ErrorAction SilentlyContinue).Trim()
} else { '' }

if ([string]::IsNullOrWhiteSpace($installedVersion)) {
    Write-Note 'No installed version marker found; skipping version check.'
    Write-Note "If launches fail, run: $UpdateOneLiner"
    exit 0
}

if ($LatestVersionUrl -ne $DefaultLatestVersionUrl) {
    Write-Note "Using OVERRIDE version pointer URL (test mode): $LatestVersionUrl"
}

# ─── Fetch latest version ───────────────────────────────────────────────────
# Fail-open on network error so an offline launch still works. The user
# already had to launch Prism, so they're at their PC; if they're offline
# the server isn't reachable anyway and a blocked launch helps no one.
$latestRaw = $null
try {
    $resp = Invoke-WebRequest -Uri $LatestVersionUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $latestRaw = ($resp.Content -as [string]).Trim()
} catch {
    Write-Note "Could not fetch latest version pointer ($($_.Exception.Message)); allowing launch."
    exit 0
}
if ([string]::IsNullOrWhiteSpace($latestRaw)) {
    Write-Note 'Latest version pointer was empty; allowing launch.'
    exit 0
}

# ─── Compare ────────────────────────────────────────────────────────────────
# Use [version] for proper MAJOR.MINOR.PATCH ordering. If either side isn't
# parseable as a version, fall back to strict equality (covers test-channel
# tags like 'test-1' that aren't [version]-shaped).
$installedV = $null; $latestV = $null
try { $installedV = [version]$installedVersion } catch {}
try { $latestV    = [version]$latestRaw }        catch {}

if ($installedV -and $latestV) {
    if ($installedV -ge $latestV) {
        # Up to date OR ahead of latest (e.g. dev-installed pre-release). The
        # downgrade-guard in update.ps1 prevents accidental rollback if the
        # admin republishes an older blob without allowDowngrade:true, so a
        # player on a newer version stays on it.
        exit 0
    }
} else {
    if ($installedVersion -eq $latestRaw) { exit 0 }
    # Unparseable on either side -> allow launch (we'd rather fail-open than
    # block a player because of a tag format we didn't anticipate).
    Write-Note "Version strings not [version]-parseable (installed='$installedVersion', latest='$latestRaw'); allowing launch."
    exit 0
}

# ─── Block launch with clear instructions ───────────────────────────────────
# Exit 1 makes Prism refuse to launch the game. Players get this banner in
# Prism's pre-launch console window.
Write-Host ''
Write-Note '============================================================'
Write-Note "  UPDATE REQUIRED  -  installed v$installedVersion, latest v$latestRaw"
Write-Note '============================================================'
Write-Note ''
Write-Note 'The server is pinned to the latest modpack version, so joining'
Write-Note 'with an older client would fail at the FML handshake.'
Write-Note ''
Write-Note 'Run this in a NEW PowerShell window to update (close Prism first):'
Write-Note ''
Write-Note "  $UpdateOneLiner"
Write-Note ''
Write-Note "Walk-through: $WikiUrl"
Write-Note ''
Write-Note '(Set $env:NEGATIVEZONE_SKIP_VERSION_CHECK=1 to bypass for offline play.)'
Write-Host ''
exit 1
