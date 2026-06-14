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
#   - Installed version == latest version  (strict equality)
#   - Both versions unparseable AND identical as strings
#   - $env:NEGATIVEZONE_SKIP_VERSION_CHECK = '1' bypass set
#
# Fail-closed (exit 1, block launch):
#   - Installed version != latest version  ->  blocks in EITHER direction
#     (upgrade required when behind, rollback required when ahead). The
#     lifecycle scripts are not production-stable yet, so the operator
#     wants every version delta to force the user through the explicit
#     update flow until each path is shaken out in real use. We'll relax
#     this to "block on MINOR delta only" once the toolchain is trusted.

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
# Strict equality in either direction. Use [version] when both sides parse so
# 1.10.0 sorts correctly vs 1.9.0; fall back to string-eq when either side is
# non-semver (we still block on mismatch — the policy says ANY delta blocks).
$installedV = $null; $latestV = $null
try { $installedV = [version]$installedVersion } catch {}
try { $latestV    = [version]$latestRaw }        catch {}

$mismatchDirection = 'mismatch'
if ($installedV -and $latestV) {
    if ($installedV -eq $latestV) { exit 0 }
    $mismatchDirection = if ($installedV -lt $latestV) { 'behind' } else { 'ahead' }
} else {
    if ($installedVersion -eq $latestRaw) { exit 0 }
    Write-Note "Version strings not [version]-parseable (installed='$installedVersion', latest='$latestRaw'); falling back to string compare."
}

# ─── Block launch with clear instructions ───────────────────────────────────
# Exit 1 makes Prism refuse to launch the game. Players get this banner in
# Prism's pre-launch console window. The direction hint helps the user
# understand whether they need to update (behind) or roll back (ahead).
Write-Host ''
Write-Note '============================================================'
Write-Note '  MODPACK VERSION MISMATCH'
Write-Note "  installed: v$installedVersion"
Write-Note "  server:    v$latestRaw  ($mismatchDirection)"
Write-Note '============================================================'
Write-Note ''
Write-Note 'The server is pinned to a specific modpack version. Joining with'
Write-Note 'a different client version would fail at the FML handshake.'
Write-Note ''
Write-Note 'Run this in a NEW PowerShell window (close Prism first):'
Write-Note ''
Write-Note "  $UpdateOneLiner"
Write-Note ''
if ($mismatchDirection -eq 'ahead') {
    Write-Note '(Your client is AHEAD of the server. update.ps1 will refuse a'
    Write-Note ' rollback unless the admin opted in via allowDowngrade:true.'
    Write-Note ' If you need to force a rollback, contact the admin.)'
    Write-Note ''
}
Write-Note "Walk-through: $WikiUrl"
Write-Note ''
Write-Note '(Set $env:NEGATIVEZONE_SKIP_VERSION_CHECK=1 to bypass for offline play.)'
Write-Host ''
exit 1
