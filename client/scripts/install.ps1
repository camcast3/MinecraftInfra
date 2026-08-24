# NegativeZone Minecraft installer (nz client bootstrap)
#
# Player one-liner (first install):
#   irm https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/install.ps1 | iex
#
# What it does:
#   1. Installs Java 17 (Temurin) + Prism Launcher via winget (skips if present).
#   2. Downloads the nz client to %LOCALAPPDATA%\NegativeZone\nz.exe.
#   3. Runs `nz setup` — pulls the modpack from Azure, wires Prism's launch/exit
#      hooks, and drops an "Update Craft to Exile 2" launcher on your Desktop.
#
# No admin rights needed. Re-running is safe: it upgrades in place and
# preserves your worlds, waypoints, and tuned settings.
#
# Test/override env vars (admins only):
#   NEGATIVEZONE_NZ_EXE_PATH  - use a LOCAL nz.exe (copied, not downloaded). Lets
#                               you test a freshly-built binary end-to-end without
#                               publishing to GitHub. Takes precedence over the URL.
#   NEGATIVEZONE_NZ_RELEASE_URL - override nz-release.json (URL or local path)
#   NEGATIVEZONE_NZ_EXE_URL   - override the nz.exe download URL; requires
#                               NEGATIVEZONE_NZ_EXE_SHA256
#   NEGATIVEZONE_NZ_EXE_SHA256 - expected SHA-256 for an overridden binary URL
#   NEGATIVEZONE_MANIFEST_URL - override the modpack manifest (test channel)
#   NEGATIVEZONE_SKIP_WINGET  - '1' to skip Java/Prism winget installs
#   NEGATIVEZONE_SKIP_SETUP   - '1' to install/verify nz.exe without running setup

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [warn] $msg" -ForegroundColor Yellow }

$DefaultNzReleaseUrl = 'https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/nz-release.json'
$NzExeLocalPath = $env:NEGATIVEZONE_NZ_EXE_PATH
$NzReleaseUrl = if ($env:NEGATIVEZONE_NZ_RELEASE_URL) {
    $env:NEGATIVEZONE_NZ_RELEASE_URL
} else {
    $DefaultNzReleaseUrl
}

function Get-NzReleaseMetadata {
    param([Parameter(Mandatory)][string] $Location)

    if (Test-Path -LiteralPath $Location -PathType Leaf) {
        return Get-Content -LiteralPath $Location -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return Invoke-RestMethod -Uri $Location -UseBasicParsing
}

function Assert-SHA256 {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Expected
    )

    $expectedNormalized = $Expected.Trim().ToLowerInvariant()
    if ($expectedNormalized -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid expected nz.exe SHA-256: '$Expected'"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expectedNormalized) {
        throw "nz.exe SHA-256 mismatch: expected $expectedNormalized, got $actual"
    }
    Write-Ok "nz.exe SHA-256 verified: $actual"
}

Write-Host ''
Write-Host 'NegativeZone Minecraft installer' -ForegroundColor Magenta
Write-Host '--------------------------------'

# ─── 1. Java 17 + Prism Launcher (winget) ────────────────────────────────────
if ($env:NEGATIVEZONE_SKIP_WINGET -eq '1') {
    Write-Warn 'NEGATIVEZONE_SKIP_WINGET=1 - skipping Java/Prism installation.'
} else {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Warn 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
        Write-Warn 'https://apps.microsoft.com/detail/9NBLGGH4NNS1'
    } else {
        Write-Step 'Checking Java 17'
        $java = Get-Command java -ErrorAction SilentlyContinue
        $haveJava17 = $false
        if ($java) {
            # `java -version` prints to STDERR. Under $ErrorActionPreference='Stop',
            # Windows PowerShell 5.1 promotes that native stderr write to a
            # terminating NativeCommandError, so relax the preference locally.
            $verText = ''
            $prevEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $verText = (& java -version 2>&1 | ForEach-Object { "$_" }) -join ' '
            } catch {
                $verText = ''
            } finally {
                $ErrorActionPreference = $prevEap
            }
            if ($verText -match 'version "17\.') { $haveJava17 = $true }
        }
        if ($haveJava17) {
            Write-Ok 'Java 17 already installed.'
        } else {
            Write-Step 'Installing Java 17 (Temurin) via winget'
            winget install --id EclipseAdoptium.Temurin.17.JDK -e --source winget `
                --accept-package-agreements --accept-source-agreements
            Write-Ok 'Java 17 installed.'
        }

        Write-Step 'Checking Prism Launcher'
        $prismInstalled = (winget list --id PrismLauncher.PrismLauncher -e 2>$null |
            Select-String 'PrismLauncher.PrismLauncher')
        if ($prismInstalled) {
            Write-Ok 'Prism Launcher already installed.'
        } else {
            Write-Step 'Installing Prism Launcher via winget'
            winget install --id PrismLauncher.PrismLauncher -e --source winget `
                --accept-package-agreements --accept-source-agreements
            Write-Ok 'Prism Launcher installed.'
        }
    }
}

# ─── 2. Obtain nz.exe into a stable location ─────────────────────────────────
$nzDir = Join-Path $env:LOCALAPPDATA 'NegativeZone'
New-Item -ItemType Directory -Path $nzDir -Force | Out-Null
$nzExe = Join-Path $nzDir 'nz.exe'

if ($NzExeLocalPath) {
    # Local-binary mode: copy a freshly-built nz.exe instead of downloading.
    # Lets you test the full install.ps1 flow end-to-end against an unreleased
    # build (e.g. `go build -o nz.exe ./cmd/nz`) without publishing to GitHub.
    Write-Step 'Installing the nz client (LOCAL build)'
    Write-Warn "Using LOCAL nz.exe: $NzExeLocalPath"
    if (-not (Test-Path -LiteralPath $NzExeLocalPath)) {
        throw "NEGATIVEZONE_NZ_EXE_PATH points at a file that doesn't exist: $NzExeLocalPath"
    }
    try {
        Copy-Item -LiteralPath $NzExeLocalPath -Destination $nzExe -Force
        Write-Ok "nz client copied to $nzExe"
    } catch {
        throw "Failed to copy local nz client from $NzExeLocalPath : $($_.Exception.Message)"
    }
} else {
    Write-Step 'Downloading the nz client'
    $expectedSHA = $env:NEGATIVEZONE_NZ_EXE_SHA256
    $expectedSize = 0L
    if ($env:NEGATIVEZONE_NZ_EXE_URL) {
        $NzExeUrl = $env:NEGATIVEZONE_NZ_EXE_URL
        if (-not $expectedSHA) {
            throw 'NEGATIVEZONE_NZ_EXE_URL requires NEGATIVEZONE_NZ_EXE_SHA256; refusing an unverified binary.'
        }
        Write-Warn "Using OVERRIDE nz.exe URL: $NzExeUrl"
    } else {
        Write-Step 'Resolving the gated stable nz release'
        try {
            $release = Get-NzReleaseMetadata -Location $NzReleaseUrl
        } catch {
            throw "Failed to fetch nz release metadata from $NzReleaseUrl : $($_.Exception.Message)"
        }
        if ($release.schemaVersion -ne 1 -or -not $release.tag -or
            -not $release.binary.url -or -not $release.binary.sha256) {
            throw "Malformed nz release metadata at $NzReleaseUrl"
        }
        $NzExeUrl = [string]$release.binary.url
        $expectedSHA = [string]$release.binary.sha256
        $expectedSize = [int64]$release.binary.sizeBytes

        # The stable alias is only a pointer. The binary itself must live on an
        # immutable, commit-versioned release tag.
        if ($NzReleaseUrl -eq $DefaultNzReleaseUrl) {
            $escapedTag = [regex]::Escape([string]$release.tag)
            if ($release.tag -eq 'nz-latest' -or
                $NzExeUrl -notmatch "/releases/download/$escapedTag/nz\.exe$") {
                throw "Stable nz metadata does not point at an immutable versioned release."
            }
        }
        Write-Ok "Resolved gated release $($release.tag)"
    }

    $downloadPath = "$nzExe.download-$PID"
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    try {
        if (Test-Path -LiteralPath $NzExeUrl -PathType Leaf) {
            Copy-Item -LiteralPath $NzExeUrl -Destination $downloadPath -Force
        } else {
            Invoke-WebRequest -Uri $NzExeUrl -OutFile $downloadPath -UseBasicParsing
        }
        if ($expectedSize -gt 0 -and (Get-Item -LiteralPath $downloadPath).Length -ne $expectedSize) {
            throw "nz.exe size mismatch: expected $expectedSize bytes, got $((Get-Item -LiteralPath $downloadPath).Length)"
        }
        Assert-SHA256 -Path $downloadPath -Expected $expectedSHA
        Move-Item -LiteralPath $downloadPath -Destination $nzExe -Force
        Write-Ok "Verified nz client saved to $nzExe"
    } catch {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        throw "Failed to install nz client from $NzExeUrl : $($_.Exception.Message)"
    }
}

# ─── 3. Run the install ──────────────────────────────────────────────────────
if ($env:NEGATIVEZONE_SKIP_SETUP -eq '1') {
    Write-Warn 'NEGATIVEZONE_SKIP_SETUP=1 - binary verification complete; skipping nz setup.'
    return
}

Write-Step 'Installing the Craft to Exile 2 modpack'
# NEGATIVEZONE_NONINTERACTIVE lets `nz setup` skip its confirm prompt when this
# bootstrap is piped via `irm | iex` (no TTY). Players just wait ~2 minutes.
$env:NEGATIVEZONE_NONINTERACTIVE = '1'
& $nzExe setup
$rc = $LASTEXITCODE

if ($rc -ne 0) {
    Write-Warn "Setup exited with code $rc. Re-run this installer to retry."
    return
}

Write-Host ''
Write-Host 'Done!' -ForegroundColor Green
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Open Prism Launcher and sign in with your Microsoft account.'
Write-Host '  2. Send the admin your Minecraft Java username so you can be allowlisted.'
Write-Host '  3. Launch "Craft to Exile 2" and add the server: mc.negativezone.cc'
Write-Host ''
Write-Host 'When a new version ships, double-click "Update Craft to Exile 2" on your Desktop.' -ForegroundColor Cyan
Write-Host ''
