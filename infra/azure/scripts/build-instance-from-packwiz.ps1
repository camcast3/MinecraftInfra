#requires -Version 7.0
<#
.SYNOPSIS
    Materialize a clean Prism Launcher instance from the committed packwiz
    manifest, ready to be sanitized + zipped + uploaded by publish-prism-pack.ps1.

.DESCRIPTION
    Bridges PR 1's packwiz manifest to PR 2's published client zip. Replaces
    the hand-maintained Prism instance with a manifest-driven materialization,
    so every published client zip is gated by `packwiz/pack.toml` at the
    publish-time commit SHA.

    Steps:
      1. Sanity-check packwiz/pack.toml exists, java is on PATH.
      2. Read Forge + Minecraft versions from packwiz/pack.toml's [versions]
         block so the generated mmc-pack.json mirrors what the server runs.
      3. Cache packwiz-installer-bootstrap.jar at infra/azure/scripts/cache/.
         The JAR version is pinned to $BootstrapVersion below and bumped
         manually per the project's "Renovate excludes JAR lifecycle" rule.
      4. Recreate the staging instance dir from scratch under <RepoRoot>/build/
         (cleaning any prior run) with:
           - `instance.cfg`   minimal Prism instance metadata; the
             publish script will sanitize this further (AutomaticJava=true,
             memory caps, iconKey override).
           - `mmc-pack.json`  component list matching the loader + MC
             versions read from pack.toml.
           - `.minecraft/`    empty; packwiz-installer fills it next.
      5. Invoke `java -jar packwiz-installer-bootstrap.jar -g -s client <pack-url>`
         inside `.minecraft/`. `-s client` skips `side = "server"` overlay
         JARs (PCF, spark, prom-exporter) that have no business in a
         player's instance. The URL points at the live committed manifest
         on disk, NOT a SHA-pinned raw.githubusercontent.com URL — at
         build time we want HEAD of the local working tree, because the
         publish script's commit-and-bump step is what turns HEAD into the
         pinned production SHA later.
      6. Emit the staging instance path on stdout so callers can pipe it
         into publish-prism-pack.ps1's -InstancePath argument.

.PARAMETER InstanceName
    Folder name to use for the staging instance. Must match the
    InstanceName publish-prism-pack.ps1 will sanitize against (default for
    both is "Craft to Exile 2") so the zip layout matches what setup.ps1
    expects in players' %APPDATA%\PrismLauncher\instances\.

.PARAMETER StagingRoot
    Directory under which the staging instance is materialized. Defaults
    to <RepoRoot>/build/ — under .gitignore so the staged tree never gets
    accidentally committed. The full materialized path is
    "$StagingRoot\$InstanceName".

.PARAMETER PackwizDir
    Path to the packwiz manifest directory. Defaults to packwiz/ at the
    repo root (resolved relative to this script).

.PARAMETER BootstrapVersion
    GitHub release tag of packwiz/packwiz-installer-bootstrap to download.
    Pinned to keep the build reproducible across machines; bump this
    deliberately when PR 4's daily workflow flags drift. Per project rule,
    Renovate is excluded from JAR lifecycle, so bumps are manual.

.PARAMETER BootstrapJar
    Override path to a local packwiz-installer-bootstrap.jar. Skips the
    download step. Useful for offline / air-gapped admin runs.

.PARAMETER CacheDir
    Directory used to cache packwiz-installer-bootstrap.jar across runs.
    Defaults to infra/azure/scripts/cache/ (under .gitignore).

.EXAMPLE
    # Standard flow — materialize the staging instance, then pass the path
    # to publish-prism-pack.ps1:
    $stagingPath = ./infra/azure/scripts/build-instance-from-packwiz.ps1
    ./infra/azure/scripts/publish-prism-pack.ps1 -InstancePath $stagingPath -Version 0.4.0

.EXAMPLE
    # Materialize without re-downloading the bootstrap jar:
    ./infra/azure/scripts/build-instance-from-packwiz.ps1 -BootstrapJar C:\tools\packwiz-installer-bootstrap.jar

.NOTES
    Requires:
      - Java 17+ on PATH (`java -version`). itzg's image uses Temurin 17;
        the player onboarding install Temurin 17 via winget. Matching here
        keeps materialization behavior identical to runtime.
      - Network access to GitHub (release download) and CurseForge / Modrinth
        (per-mod downloads). Admin should have CURSEFORGE_API_KEY set in
        the environment to avoid CF rate limits on the ~390-mod install.
#>

[CmdletBinding()]
param(
    [string] $InstanceName = 'Craft to Exile 2',
    [string] $StagingRoot,
    [string] $PackwizDir,
    [string] $BootstrapVersion = 'v0.0.3',
    [string] $BootstrapJar,
    [string] $CacheDir
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $true

function Resolve-AbsolutePath {
    param([string] $Path)
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Get-RepoRoot {
    $top = git rev-parse --show-toplevel 2>$null
    if (-not $top) {
        throw "Could not resolve repo root via 'git rev-parse --show-toplevel'. Are you inside the MinecraftInfra worktree?"
    }
    return ($top | Out-String).Trim()
}

# Defaults that depend on the repo root must be resolved after the param
# block so callers can still override any of them.
$repoRoot = Get-RepoRoot
if (-not $PackwizDir)   { $PackwizDir   = Join-Path $repoRoot 'packwiz' }
if (-not $StagingRoot)  { $StagingRoot  = Join-Path $repoRoot 'build' }
if (-not $CacheDir)     { $CacheDir     = Join-Path $PSScriptRoot 'cache' }

if (-not (Test-Path -LiteralPath $PackwizDir -PathType Container)) {
    throw "PackwizDir not found: $PackwizDir"
}
$PackwizDir = Resolve-AbsolutePath $PackwizDir

$packToml = Join-Path $PackwizDir 'pack.toml'
if (-not (Test-Path -LiteralPath $packToml)) {
    throw "packwiz/pack.toml not found at $packToml — has PR 1's bootstrap landed?"
}

# ─── Java preflight ─────────────────────────────────────────────────────────
$java = Get-Command java -ErrorAction SilentlyContinue
if (-not $java) {
    throw @"
java not found on PATH. packwiz-installer-bootstrap requires a JVM.
On Windows: winget install --id EclipseAdoptium.Temurin.17.JDK -e --source winget
"@
}
Write-Information "Using java at: $($java.Source)"

# ─── Parse pack.toml versions ───────────────────────────────────────────────
# We need MC + Forge versions for mmc-pack.json. packwiz emits them as:
#   [versions]
#   forge = "47.4.10"
#   minecraft = "1.20.1"
# Tiny TOML probe — avoids pulling a real parser into the admin toolchain.
$packTomlContent = Get-Content -Raw -LiteralPath $packToml
$mcMatch    = [regex]::Match($packTomlContent, '(?m)^minecraft\s*=\s*"([^"]+)"')
$forgeMatch = [regex]::Match($packTomlContent, '(?m)^forge\s*=\s*"([^"]+)"')
if (-not $mcMatch.Success) {
    throw "Could not find minecraft = ""..."" in $packToml"
}
if (-not $forgeMatch.Success) {
    throw "Could not find forge = ""..."" in $packToml — only Forge loader is supported by this builder."
}
$minecraftVersion = $mcMatch.Groups[1].Value
$forgeVersion    = $forgeMatch.Groups[1].Value
Write-Information "Manifest versions: Minecraft $minecraftVersion / Forge $forgeVersion"

# ─── Bootstrap JAR (cached, version-pinned) ────────────────────────────────
if ($BootstrapJar) {
    if (-not (Test-Path -LiteralPath $BootstrapJar)) {
        throw "BootstrapJar override not found: $BootstrapJar"
    }
    $BootstrapJar = Resolve-AbsolutePath $BootstrapJar
    Write-Information "Using bootstrap jar override: $BootstrapJar"
} else {
    if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }
    # Pin the cached filename to the version so a manual bump doesn't pick up
    # a stale jar from a previous run. Cleanup of old versions is left to the
    # admin — they're a few MB each.
    $BootstrapJar = Join-Path $CacheDir "packwiz-installer-bootstrap-$BootstrapVersion.jar"
    if (-not (Test-Path -LiteralPath $BootstrapJar)) {
        $url = "https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/$BootstrapVersion/packwiz-installer-bootstrap.jar"
        Write-Information "Downloading packwiz-installer-bootstrap $BootstrapVersion from $url"
        Invoke-WebRequest -Uri $url -OutFile $BootstrapJar -UseBasicParsing
    } else {
        Write-Information "Reusing cached bootstrap jar at $BootstrapJar"
    }
}

# ─── Staging directory ──────────────────────────────────────────────────────
# Recreate from scratch each run. Leftover .pw.toml entries from a previous
# pack version that were since dropped would otherwise persist into the
# published zip and confuse Forge's mod loader.
$stagingInstance = Join-Path $StagingRoot $InstanceName
if (Test-Path -LiteralPath $stagingInstance) {
    Write-Information "Cleaning prior staging instance: $stagingInstance"
    Remove-Item -Recurse -Force -LiteralPath $stagingInstance
}
$dotMinecraft = Join-Path $stagingInstance '.minecraft'
New-Item -ItemType Directory -Path $dotMinecraft -Force | Out-Null
Write-Information "Created staging instance at: $stagingInstance"

# ─── instance.cfg ───────────────────────────────────────────────────────────
# Minimal Prism instance.cfg. publish-prism-pack.ps1 will sanitize this
# further (AutomaticJava, memory caps, iconKey, etc.) so we only need the
# fields Prism requires to import the folder as an instance at all. The
# name= line gets rewritten with the version suffix at publish time.
$instanceCfg = @"
[General]
ConfigVersion=1.2
InstanceType=OneSix
JoinServerOnLaunch=false
MCLaunchMethod=LauncherPart
ManagedPack=false
ManagedPackID=
ManagedPackName=
ManagedPackType=
ManagedPackVersionID=
ManagedPackVersionName=
OverrideCommands=false
OverrideJavaArgs=false
OverrideJavaLocation=false
OverrideMemory=false
OverrideMiscellaneous=false
OverrideWindow=false
notes=Built from packwiz manifest by build-instance-from-packwiz.ps1
iconKey=default
name=$InstanceName
"@
Set-Content -LiteralPath (Join-Path $stagingInstance 'instance.cfg') -Value $instanceCfg -Encoding UTF8
Write-Information 'Wrote instance.cfg'

# ─── mmc-pack.json ──────────────────────────────────────────────────────────
# Components Prism uses to build the launch classpath. LWJGL pin matches
# what Prism's metadata server records for Minecraft 1.20.1 — bumping MC
# may require bumping this too (Prism would normally re-resolve it at
# import time, but a wrong value here keeps the zip self-contained and
# importable offline).
$mmcPack = [pscustomobject]@{
    components    = @(
        [pscustomobject]@{
            cachedName       = 'LWJGL 3'
            cachedVersion    = '3.3.1'
            cachedVolatile   = $true
            dependencyOnly   = $true
            uid              = 'org.lwjgl3'
            version          = '3.3.1'
        },
        [pscustomobject]@{
            cachedName     = 'Minecraft'
            cachedRequires = @(
                [pscustomobject]@{
                    suggests = '3.3.1'
                    uid      = 'org.lwjgl3'
                }
            )
            cachedVersion  = $minecraftVersion
            important      = $true
            uid            = 'net.minecraft'
            version        = $minecraftVersion
        },
        [pscustomobject]@{
            cachedName     = 'Forge'
            cachedRequires = @(
                [pscustomobject]@{
                    equals = $minecraftVersion
                    uid    = 'net.minecraft'
                }
            )
            cachedVersion  = $forgeVersion
            uid            = 'net.minecraftforge'
            version        = $forgeVersion
        }
    )
    formatVersion = 1
}
$mmcPack | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $stagingInstance 'mmc-pack.json') -Encoding UTF8
Write-Information "Wrote mmc-pack.json (MC $minecraftVersion / Forge $forgeVersion)"

# ─── Run packwiz-installer-bootstrap ────────────────────────────────────────
# Point at the local pack.toml via a file:// URL so we materialize EXACTLY
# what's in the working tree, not what's on `main` or any other branch.
# The publish flow's commit step (in publish-prism-pack.ps1) is what
# captures the SHA and pins it into docker/proxmox/.env — at build time
# we just want the working-tree state.
#
# Java's URL handler treats file:// URIs as fetchable inputs to
# packwiz-installer-bootstrap; the bootstrap then walks index.toml + each
# .pw.toml and fetches their actual download URLs (which are real HTTPS
# in every case).
$packTomlUri = ([System.Uri](Resolve-AbsolutePath $packToml)).AbsoluteUri
Write-Information ''
Write-Information '── packwiz-installer-bootstrap (--side client) ──'
Push-Location $dotMinecraft
try {
    & java -jar $BootstrapJar -g -s client $packTomlUri
    if ($LASTEXITCODE -ne 0) {
        throw "packwiz-installer-bootstrap failed (exit $LASTEXITCODE). See output above for the offending mod or URL."
    }
}
finally {
    Pop-Location
}

# ─── Sanity check the install ───────────────────────────────────────────────
$modsDir = Join-Path $dotMinecraft 'mods'
if (-not (Test-Path -LiteralPath $modsDir)) {
    throw "packwiz-installer ran but produced no $modsDir directory. Aborting — publish would ship an empty instance."
}
$installedMods = (Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue).Count
if ($installedMods -lt 1) {
    throw "Expected at least one .jar in $modsDir; found none. Did the manifest install fail silently?"
}
Write-Information ''
Write-Information "Materialized $installedMods mod JAR(s) into $modsDir"

# Pipe the path on stdout for the caller to capture. Everything above this
# point writes to the Information stream so the captured value is purely
# the path — `$path = ./build-instance-from-packwiz.ps1` works.
Write-Output $stagingInstance
