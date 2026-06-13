#requires -Version 7.0
<#
.SYNOPSIS
    Import a Craft to Exile 2 CurseForge zip into packwiz/ and re-add the
    three server-only overlay mods (spark, Proxy-Compatible-Forge,
    minecraft-prometheus-exporter) on top.

.DESCRIPTION
    `packwiz curseforge import` recreates pack.toml + index.toml + mods/
    from scratch — it does not merge. So every C2E2 upstream bump would
    wipe the three server-only overlay mods. This script snapshots them,
    runs the import, re-adds them at pinned URLs with side="server",
    syncs FORGE_VERSION into docker/proxmox/docker-compose.yml, and
    `packwiz refresh`es the index. Review the resulting `git status`
    diff before committing.

.PARAMETER PackZip
    Path to the C2E2 CurseForge zip (Files tab → manual download from
    curseforge.com/minecraft/modpacks/craft-to-exile-2).

.PARAMETER PackwizDir
    Defaults to packwiz/ at the repo root.

.PARAMETER CurseForgeApiKey
    Optional. From https://console.curseforge.com/. Defaults to
    $env:CURSEFORGE_API_KEY. Without it, packwiz uses the public CFCore
    proxy (subject to rate limits on large packs).

.PARAMETER YesAllPrompts
    Pass -y to every packwiz call (use for CI).

.EXAMPLE
    ./infra/azure/scripts/import-curseforge-pack.ps1 -PackZip 'C:\Downloads\Craft+To+Exile+2-0.4.0.zip'

.NOTES
    Requires the packwiz CLI on PATH:
        go install github.com/packwiz/packwiz@latest
    Prebuilt binaries: https://nightly.link/packwiz/packwiz/workflows/go/main
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackZip,

    [string] $PackwizDir,

    [string] $CurseForgeApiKey = $env:CURSEFORGE_API_KEY,

    [switch] $YesAllPrompts
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Resolve-AbsolutePath {
    param([string] $Path)
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

# Keep these in lockstep with the .pw.toml content under packwiz/mods/.
$OverlayMods = @(
    [pscustomobject]@{
        Name      = 'spark'
        Source    = 'modrinth'
        ProjectId = 'l6YH9Als'
        Filename  = 'spark-1.10.53-forge.jar'
    },
    [pscustomobject]@{
        Name = 'proxy-compatible-forge'
        Source = 'url'
        Url  = 'https://github.com/adde0109/Proxy-Compatible-Forge/releases/download/v1.2.6/proxy-compatible-forge-1.2.6.jar'
    },
    [pscustomobject]@{
        Name = 'minecraft-prometheus-exporter'
        Source = 'url'
        Url  = 'https://github.com/cpburnz/minecraft-prometheus-exporter/releases/download/1.20.1-forge-1.2.1/Prometheus-Exporter-1.20.1-forge-1.2.1.jar'
    }
)

$packwiz = Get-Command packwiz -ErrorAction SilentlyContinue
if (-not $packwiz) {
    Write-Error @'
packwiz CLI not found on PATH. Install with:
    go install github.com/packwiz/packwiz@latest
or grab a prebuilt binary from
    https://nightly.link/packwiz/packwiz/workflows/go/main
and put it on PATH.
'@
    exit 1
}
Write-Information "Using packwiz at: $($packwiz.Source)"

if (-not (Test-Path -LiteralPath $PackZip)) {
    Write-Error "PackZip not found: $PackZip"
    exit 1
}
$PackZip = Resolve-AbsolutePath $PackZip

if (-not $PackwizDir) {
    $PackwizDir = Join-Path $PSScriptRoot '..\..\..\packwiz'
}
if (-not (Test-Path -LiteralPath $PackwizDir -PathType Container)) {
    Write-Error "PackwizDir not found: $PackwizDir"
    exit 1
}
$PackwizDir = Resolve-AbsolutePath $PackwizDir
Write-Information "Working directory: $PackwizDir"
Write-Information "CurseForge zip   : $PackZip"

if ($CurseForgeApiKey) {
    $env:CURSEFORGE_API_KEY = $CurseForgeApiKey
    Write-Information 'CURSEFORGE_API_KEY set for this process.'
} else {
    Write-Warning 'No CurseForge API key — packwiz will use the public CFCore proxy. Subject to rate limits on large packs.'
}

$yesArgs = @()
if ($YesAllPrompts) { $yesArgs = @('-y') }

Push-Location $PackwizDir
try {
    # Snapshot overlays before import — audit trail + diff target for the operator.
    $stagingDir = Join-Path $PackwizDir '.import-staging'
    if (Test-Path $stagingDir) { Remove-Item -Recurse -Force $stagingDir }
    New-Item -ItemType Directory -Path $stagingDir | Out-Null
    foreach ($mod in $OverlayMods) {
        $src = Join-Path $PackwizDir "mods\$($mod.Name).pw.toml"
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $stagingDir
            Write-Information "Snapshotted overlay file: $($mod.Name).pw.toml"
        }
    }

    Write-Information ''
    Write-Information '── packwiz curseforge import ──'
    & packwiz curseforge import @yesArgs $PackZip
    if ($LASTEXITCODE -ne 0) {
        throw "packwiz curseforge import failed (exit $LASTEXITCODE)."
    }

    Write-Information ''
    Write-Information '── Re-adding overlay mods ──'
    foreach ($mod in $OverlayMods) {
        Write-Information "  + $($mod.Name) ($($mod.Source))"
        switch ($mod.Source) {
            'modrinth' {
                & packwiz modrinth add --project-id $mod.ProjectId --version-filename $mod.Filename @yesArgs
            }
            'url' {
                & packwiz url add $mod.Name $mod.Url @yesArgs
            }
            default { throw "Unknown overlay source: $($mod.Source)" }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "packwiz failed adding overlay $($mod.Name) (exit $LASTEXITCODE)."
        }
    }

    # Flip overlays to side="server" so PR 2's publish flow skips them in the client zip.
    foreach ($mod in $OverlayMods) {
        $modFile = Join-Path $PackwizDir "mods\$($mod.Name).pw.toml"
        if (-not (Test-Path -LiteralPath $modFile)) {
            throw "Expected $modFile after re-add, but it's missing."
        }
        $content = Get-Content -Raw -LiteralPath $modFile
        # Pattern stops at the closing quote so blank lines in the TOML stay intact
        # ($-anchored \s would eat CRLF on Windows).
        $rewritten = [regex]::Replace(
            $content,
            '(?m)^side[ \t]*=[ \t]*"(both|client)"',
            'side = "server"'
        )
        if ($rewritten -eq $content) {
            Write-Warning "  ! No side= line rewritten in $($mod.Name).pw.toml — verify manually."
        } else {
            Set-Content -LiteralPath $modFile -Value $rewritten -NoNewline
            Write-Information "  ~ $($mod.Name): side -> server"
        }
    }

    # Sync forge= from pack.toml into docker/proxmox/docker-compose.yml's FORGE_VERSION.
    $packToml = Join-Path $PackwizDir 'pack.toml'
    $packForgeMatch = (Get-Content -Raw -LiteralPath $packToml) |
        Select-String -Pattern '(?m)^forge\s*=\s*"([^"]+)"'
    if (-not $packForgeMatch) {
        Write-Warning 'Could not detect forge= in packwiz/pack.toml — skipping FORGE_VERSION sync.'
    } else {
        $packForge = $packForgeMatch.Matches[0].Groups[1].Value
        $composeFile = Resolve-AbsolutePath (Join-Path $PackwizDir '..\docker\proxmox\docker-compose.yml')
        $composeContent = Get-Content -Raw -LiteralPath $composeFile
        $composeForgeMatch = $composeContent | Select-String -Pattern '(?m)^\s*FORGE_VERSION:\s*"([^"]+)"'
        if (-not $composeForgeMatch) {
            Write-Warning "No FORGE_VERSION: line found in $composeFile — please add it."
        } else {
            $composeForge = $composeForgeMatch.Matches[0].Groups[1].Value
            if ($composeForge -eq $packForge) {
                Write-Information "FORGE_VERSION already matches packwiz: $packForge"
            } else {
                Write-Information "Updating FORGE_VERSION: $composeForge -> $packForge"
                $newCompose = [regex]::Replace(
                    $composeContent,
                    '(?m)(^\s*FORGE_VERSION:\s*")[^"]+(")',
                    "`${1}$packForge`${2}"
                )
                Set-Content -LiteralPath $composeFile -Value $newCompose -NoNewline
            }
        }
    }

    Write-Information ''
    Write-Information '── packwiz refresh ──'
    & packwiz refresh
    if ($LASTEXITCODE -ne 0) {
        throw "packwiz refresh failed (exit $LASTEXITCODE)."
    }

    # Clean up staging — .packwizignore prevents indexing but belt-and-braces.
    if (Test-Path $stagingDir) {
        Remove-Item -Recurse -Force $stagingDir
        Write-Information "Cleaned up $stagingDir"
    }
}
finally {
    Pop-Location
}

Write-Information ''
Write-Information '── git status ──'
& git status --short
Write-Information ''
Write-Information @'
Done. Next steps:
  1. Review the diff (especially the new mods/*.pw.toml files for any
     surprises) and commit on your PR branch.
  2. Push and let CI validate.
  3. After merge, bump docker/proxmox/.env's PACKWIZ_COMMIT_SHA to the
     merge commit so the production server pulls this manifest snapshot
     (PR 2's publish-prism-pack.ps1 does this automatically as part of
     shipping a new client zip).
'@
