# NegativeZone Minecraft setup script
#
# Run from PowerShell (no admin needed):
#   irm https://wiki.negativezone.cc/assets/setup.ps1 | iex
#
# This script:
#   1. Installs Eclipse Temurin 17 JDK via winget (if missing)
#   2. Installs Prism Launcher via winget (if missing)
#   3. Asks for your Minecraft Java username
#   4. Looks up your UUID via the Mojang API
#   5. Copies "Username + UUID" to your clipboard, ready to DM the admin

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "    [ok] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "    [warn] $msg" -ForegroundColor Yellow
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

# Mojang returns the UUID trimmed (no dashes); add them back
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

# ─── Output and clipboard ───────────────────────────────────────────────────
Write-Host ""
Write-Host "==> Send this to the admin (Cam) to get whitelisted:" -ForegroundColor Cyan
Write-Host ""
Write-Host $payload -ForegroundColor White
Write-Host ""

try {
    Set-Clipboard -Value $payload
    Write-Ok "Copied to your clipboard — paste it in Discord with Ctrl+V"
} catch {
    Write-Warn "Couldn't copy to clipboard automatically — copy the text above manually"
}

# ─── Next steps ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==> Next steps" -ForegroundColor Cyan
Write-Host "    1. Open Prism Launcher from the Start menu"
Write-Host "    2. Sign in with your Microsoft account"
Write-Host "    3. Add Instance -> CurseForge -> search 'Craft to Exile 2'"
Write-Host "    4. Wait to be whitelisted, then connect to: mc.negativezone.cc"
Write-Host ""
Write-Host "Full guide: https://wiki.negativezone.cc/player-onboarding" -ForegroundColor Cyan
Write-Host ""
