#requires -Version 7.0
<#
.SYNOPSIS
    Materialize a clean Prism Launcher instance from the committed packwiz
    manifest, ready to be sanitized + zipped + uploaded by publish-prism-pack.ps1.

    Bridges PR 1's packwiz manifest to PR 2's published client zip — every
    published client zip is gated by `packwiz/pack.toml` at the publish-time
    commit SHA. Reads loader/MC versions from pack.toml, wipes any prior
    staging dir, writes a minimal instance.cfg + mmc-pack.json, runs
    `packwiz-installer-bootstrap` against the local working tree via a
    file:// URL, and emits the staging path on stdout.

.PARAMETER InstanceName
    Folder name for the staging instance. Must match publish-prism-pack.ps1's
    -InstanceName (default for both is "Craft to Exile 2").

.PARAMETER StagingRoot
    Where the instance is materialized. Defaults to <RepoRoot>/build/
    (under .gitignore).

.PARAMETER PackwizDir
    Packwiz manifest directory. Defaults to packwiz/ at the repo root.

.PARAMETER BootstrapVersion
    GH release tag of packwiz/packwiz-installer-bootstrap. Pinned for
    reproducibility; admin bumps manually when PR 4's daily workflow flags drift.

.PARAMETER InstallerVersion
    GH release tag of packwiz/packwiz-installer. Same rationale as
    $BootstrapVersion — pinning also prevents the bootstrap from hitting
    api.github.com to discover "latest" on every run (60 req/hr unauthenticated).

.PARAMETER BootstrapJar
    Override path to a local packwiz-installer-bootstrap.jar (offline runs).

.PARAMETER InstallerJar
    Override path to a local packwiz-installer.jar (offline runs).

.PARAMETER CacheDir
    Cache for the two JARs. Defaults to infra/azure/scripts/cache/ (under
    .gitignore). Cache is separate from the staging dir because step 4 wipes
    staging every run.

.EXAMPLE
    $stagingPath = ./infra/azure/scripts/build-instance-from-packwiz.ps1
    ./infra/azure/scripts/publish-prism-pack.ps1 -InstancePath $stagingPath -Version 0.4.0

.NOTES
    Requires Java 17+ on PATH (matches itzg's runtime + player onboarding's
    Temurin 17 install). First run needs network access for the pinned JARs.
    Admin should set CURSEFORGE_API_KEY to avoid CF rate limits on the ~390-mod
    install.
#>

[CmdletBinding()]
param(
    [string] $InstanceName = 'Craft to Exile 2',
    [string] $StagingRoot,
    [string] $PackwizDir,
    [string] $BootstrapVersion = 'v0.0.3',
    [string] $InstallerVersion = 'v0.5.14',
    [string] $BootstrapJar,
    [string] $InstallerJar,
    [string] $CacheDir,
    # Single-server pack: the only entry we ship in .minecraft/servers.dat.
    # We deliberately do NOT seed the upstream CTE2 modpack's server list
    # (~30 third-party community servers); see Set-NegativeZoneServersDat.
    [string] $ServerEntryName = 'NegativeZone',
    [string] $ServerEntryAddress = 'mc.negativezone.cc',
    # 64x64 PNG to show next to the entry in Multiplayer. Defaults to the
    # committed cte2-server-icon.png (a downscale of the Prism instance
    # icon, so the launcher tile + server-list icon share branding). Pass
    # an empty string to omit the icon tag entirely. Must be exactly 64x64
    # or Minecraft's NativeImage.read() rejects it and falls back to the
    # generic Mojang icon.
    [string] $ServerEntryIconPath = (Join-Path $PSScriptRoot 'cte2-server-icon.png')
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

# Overwrites .minecraft/servers.dat with a single-entry NBT pointing at
# our Velocity proxy. This pack is a single-server offering, so we don't
# want to ship the upstream CTE2 modpack's server list (~30 third-party
# community servers like crafttoexile2-tristram.g.akliz.net, cte2.poeservers.uk,
# etc.) — players opening Multiplayer should see exactly one server: ours.
#
# We write .minecraft/servers.dat directly here (rather than relying on
# the Default Options mod to seed from config/defaultoptions/servers.dat
# on first launch) for two reasons:
#   1. Default Options only seeds when the destination is missing — if a
#      player carries forward a servers.dat from a previous install, it
#      keeps the stale list forever.
#   2. We removed config/defaultoptions/servers.dat from packwiz entirely
#      in the same change (along with its index.toml entry), so there is
#      no longer a seed source on disk.
# Update.ps1's $PreserveRelative was also updated in the same change to
# stop preserving servers.dat across pack updates, so this list propagates
# to existing installs on the next two publishes (one to swap the script,
# one to swap the file).
#
# NBT format (uncompressed; modern servers.dat is not gzipped):
#   TAG_Compound(""):
#     TAG_List<Compound>("servers"):
#       TAG_Compound: { name: TAG_String, ip: TAG_String, icon?: TAG_String }
#
# `icon` is the base64-encoding of a raw 64x64 PNG (no `data:image/png;base64,`
# prefix). Minecraft's ServerData.write() emits it this way and the client's
# ServerSelectionList feeds the decoded bytes straight into NativeImage.read(),
# which throws IllegalArgumentException unless width == height == 64 — that's
# why we validate the file's IHDR before embedding instead of letting the
# player see a fallback Mojang icon at first launch.
function Set-NegativeZoneServersDat {
    param(
        [Parameter(Mandatory = $true)][string] $DotMinecraft,
        [Parameter(Mandatory = $true)][string] $EntryName,
        [Parameter(Mandatory = $true)][string] $EntryAddress,
        # Optional. Empty/null = omit the icon tag (server list falls back
        # to Mojang's generic icon, which is what we'd see if Minecraft
        # rejected a bad PNG anyway).
        [string] $IconPath
    )

    # Pre-validate the icon before any NBT bytes are emitted. Minecraft is
    # strict about 64x64; a 192x192 PNG would silently render as the generic
    # icon and we'd never know until a player complained.
    $iconB64 = $null
    if ($IconPath) {
        if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
            throw "Server icon not found at: $IconPath"
        }
        $iconBytes = [System.IO.File]::ReadAllBytes($IconPath)
        if ($iconBytes.Length -lt 24 -or
            $iconBytes[0] -ne 0x89 -or $iconBytes[1] -ne 0x50 -or
            $iconBytes[2] -ne 0x4E -or $iconBytes[3] -ne 0x47) {
            throw "Server icon is not a valid PNG (bad signature): $IconPath"
        }
        # PNG IHDR width/height are big-endian uint32 starting at byte 16.
        $iconW = ([int]$iconBytes[16] -shl 24) -bor ([int]$iconBytes[17] -shl 16) -bor ([int]$iconBytes[18] -shl 8) -bor [int]$iconBytes[19]
        $iconH = ([int]$iconBytes[20] -shl 24) -bor ([int]$iconBytes[21] -shl 16) -bor ([int]$iconBytes[22] -shl 8) -bor [int]$iconBytes[23]
        if ($iconW -ne 64 -or $iconH -ne 64) {
            throw "Server icon must be exactly 64x64; got ${iconW}x${iconH} from: $IconPath"
        }
        $iconB64 = [Convert]::ToBase64String($iconBytes)
    }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    try {
        function script:Write-NbtU16 { param([int]$v)
            $bw.Write([byte](($v -shr 8) -band 0xFF)); $bw.Write([byte]($v -band 0xFF))
        }
        function script:Write-NbtI32 { param([int]$v)
            $bw.Write([byte](($v -shr 24) -band 0xFF))
            $bw.Write([byte](($v -shr 16) -band 0xFF))
            $bw.Write([byte](($v -shr 8) -band 0xFF))
            $bw.Write([byte]($v -band 0xFF))
        }
        function script:Write-NbtString { param([string]$s)
            $b = [System.Text.Encoding]::UTF8.GetBytes($s)
            if ($b.Length -gt 32767) { throw "NBT TAG_String '$s' exceeds 32767 bytes." }
            Write-NbtU16 $b.Length
            $bw.Write($b)
        }
        function script:Write-NbtTagString { param([string]$name, [string]$value)
            $bw.Write([byte]0x08)            # TAG_String type
            Write-NbtString $name
            Write-NbtString $value
        }

        # Root TAG_Compound, unnamed (zero-length name).
        $bw.Write([byte]0x0A); Write-NbtU16 0

        # TAG_List<Compound> named "servers", containing 1 entry.
        $bw.Write([byte]0x09); Write-NbtString 'servers'
        $bw.Write([byte]0x0A)                # element type = TAG_Compound
        Write-NbtI32 1                       # element count

        # Element compound (list elements are unnamed). Field order matches
        # what Minecraft's ServerData.write() emits so a round-trip through
        # the client doesn't reshuffle keys.
        Write-NbtTagString 'name' $EntryName
        Write-NbtTagString 'ip'   $EntryAddress
        if ($iconB64) { Write-NbtTagString 'icon' $iconB64 }
        $bw.Write([byte]0x00)                # TAG_End — closes element compound

        $bw.Write([byte]0x00)                # TAG_End — closes root compound

        $bw.Flush()
        $bytes = $ms.ToArray()
    } finally {
        $bw.Dispose()
        $ms.Dispose()
    }

    $serversDatPath = Join-Path $DotMinecraft 'servers.dat'
    [System.IO.File]::WriteAllBytes($serversDatPath, $bytes)
    $iconNote = if ($iconB64) { " (+ 64x64 icon, $($iconB64.Length) b64 chars)" } else { ' (no icon)' }
    Write-Information ("Wrote .minecraft/servers.dat ({0} bytes): '{1}' @ {2}{3}" -f $bytes.Length, $EntryName, $EntryAddress, $iconNote)
}

# Defaults that depend on the repo root must resolve after the param block.
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

# ─── Bootstrap + Installer JARs (cached, version-pinned) ───────────────────
# Both pinned + cached so step 5 can run with --bootstrap-no-update +
# --bootstrap-main-jar pointing at the cached installer — no api.github.com
# calls (60 req/hr unauthenticated, exhausted by a few test iterations).
if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

if ($BootstrapJar) {
    if (-not (Test-Path -LiteralPath $BootstrapJar)) {
        throw "BootstrapJar override not found: $BootstrapJar"
    }
    $BootstrapJar = Resolve-AbsolutePath $BootstrapJar
    Write-Information "Using bootstrap jar override: $BootstrapJar"
} else {
    # Pin cached filename to version so a manual bump doesn't pick up a
    # stale jar.
    $BootstrapJar = Join-Path $CacheDir "packwiz-installer-bootstrap-$BootstrapVersion.jar"
    if (-not (Test-Path -LiteralPath $BootstrapJar)) {
        $url = "https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/$BootstrapVersion/packwiz-installer-bootstrap.jar"
        Write-Information "Downloading packwiz-installer-bootstrap $BootstrapVersion from $url"
        Invoke-WebRequest -Uri $url -OutFile $BootstrapJar -UseBasicParsing
    } else {
        Write-Information "Reusing cached bootstrap jar at $BootstrapJar"
    }
}

if ($InstallerJar) {
    if (-not (Test-Path -LiteralPath $InstallerJar)) {
        throw "InstallerJar override not found: $InstallerJar"
    }
    $InstallerJar = Resolve-AbsolutePath $InstallerJar
    Write-Information "Using installer jar override: $InstallerJar"
} else {
    $InstallerJar = Join-Path $CacheDir "packwiz-installer-$InstallerVersion.jar"
    if (-not (Test-Path -LiteralPath $InstallerJar)) {
        $url = "https://github.com/packwiz/packwiz-installer/releases/download/$InstallerVersion/packwiz-installer.jar"
        Write-Information "Downloading packwiz-installer $InstallerVersion from $url"
        Invoke-WebRequest -Uri $url -OutFile $InstallerJar -UseBasicParsing
    } else {
        Write-Information "Reusing cached installer jar at $InstallerJar"
    }
}

# ─── Staging directory ──────────────────────────────────────────────────────
# Recreate from scratch each run. Leftover .pw.toml entries from a previous
# pack version would otherwise persist into the zip and confuse Forge.
$stagingInstance = Join-Path $StagingRoot $InstanceName
if (Test-Path -LiteralPath $stagingInstance) {
    Write-Information "Cleaning prior staging instance: $stagingInstance"
    Remove-Item -Recurse -Force -LiteralPath $stagingInstance
}
$dotMinecraft = Join-Path $stagingInstance '.minecraft'
New-Item -ItemType Directory -Path $dotMinecraft -Force | Out-Null
Write-Information "Created staging instance at: $stagingInstance"

# ─── instance.cfg ───────────────────────────────────────────────────────────
# Minimal — publish-prism-pack.ps1 sanitizes further. name= gets the version
# suffix at publish time.
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
# LWJGL pinned to what Prism's metadata server records for MC 1.20.1 —
# bumping MC may require bumping this too (Prism would re-resolve at import,
# but a wrong value here keeps the zip importable offline).
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
# file:// URL so we materialize EXACTLY the working tree, not origin/main.
# The publish script's commit step is what turns HEAD into the production
# SHA pin. Bootstrap walks index.toml + each .pw.toml from there.
# Flags: --bootstrap-no-update + --bootstrap-main-jar skip api.github.com;
# -g disables bootstrap's Swing UI (installer still shows per-mod progress);
# -s client skips `side = "server"` overlays (PCF, spark, prom-exporter).
#
# Args are splatted (not backtick-continued) because PowerShell on Linux
# silently drops args after backtick+CRLF, which is what the file ships as
# per .gitattributes' `* -text` (no EOL normalization). The CI symptom was
# `[FATAL] pack.toml URI to install from must be specified!` — the bootstrap
# only saw the bootstrap flags and lost both `-s client` and the URI.
#
# URI must be built via the two-arg Uri(base, path) constructor: a plain
# `[System.Uri]"/linux/path"` cast yields `IsAbsoluteUri = $false` and
# `.AbsoluteUri = ""` (no exception). PowerShell then silently drops the
# empty-string arg during splat, leaving java with the bootstrap flags but
# no URI — the exact same fatal as the backtick bug, so guard against both.
$packTomlAbs = Resolve-AbsolutePath $packToml
$packTomlUri = [System.Uri]::new([System.Uri]::new('file:///'), $packTomlAbs).AbsoluteUri
if ([string]::IsNullOrWhiteSpace($packTomlUri)) {
    throw "Failed to build a file:// URI for $packTomlAbs — would silently drop from java args."
}
$bootstrapArgs = @(
    '-jar', $BootstrapJar
    '--bootstrap-no-update'
    '--bootstrap-main-jar', $InstallerJar
    '-g'
    '-s', 'client'
    $packTomlUri
)
Write-Information ''
Write-Information '── packwiz-installer-bootstrap (--side client) ──'
Push-Location $dotMinecraft
try {
    & java @bootstrapArgs
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

# Seed .minecraft/servers.dat with just our Velocity proxy. Must happen
# after packwiz install (packwiz would otherwise overwrite/conflict) and
# before publish-prism-pack.ps1 zips the staging dir.
Set-NegativeZoneServersDat -DotMinecraft $dotMinecraft `
    -EntryName $ServerEntryName -EntryAddress $ServerEntryAddress `
    -IconPath $ServerEntryIconPath

# Emit staging path on stdout (everything above writes to Information stream),
# so `$path = ./build-instance-from-packwiz.ps1` captures the path verbatim.
Write-Output $stagingInstance
