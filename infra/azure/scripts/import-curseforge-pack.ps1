#requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap or refresh the `packwiz/` manifest by importing a Craft to
    Exile 2 CurseForge zip and folding the three server-only overlay mods
    (spark, Proxy-Compatible-Forge, minecraft-prometheus-exporter) back on
    top of the freshly imported pack.

.DESCRIPTION
    One-shot admin helper for PR 1's packwiz migration (server-side mods)
    and ongoing C2E2 upstream-version bumps.

    Why this script exists:
      packwiz's `curseforge import` recreates pack.toml, index.toml, and
      mods/*.pw.toml from scratch — it does NOT merge into an existing
      pack. So every C2E2 upstream bump wipes the three server-only
      overlay mods we layer on top of the upstream modpack. This script
      backs them up, runs the import, then re-adds them, so the resulting
      packwiz/ snapshot is the same shape every time.

    Steps:
      1. Sanity-check inputs (zip path, packwiz CLI available).
      2. Snapshot the existing `packwiz/mods/{spark,proxy-compatible-forge,
         minecraft-prometheus-exporter}.pw.toml` (if present) to a temp dir.
      3. `packwiz curseforge import <zip>` against `packwiz/`. This wipes
         pack.toml + index.toml + mods/ and replaces them with the upstream
         C2E2 content.
      4. Re-add the three overlay mods at the exact URLs the snapshot
         used (so version drift on the overlays is its own conscious
         decision via `packwiz update`, not an accidental side-effect of
         a C2E2 bump).
      5. Set side="server" on each overlay mod's metadata file.
      6. Sync the `forge` version in `packwiz/pack.toml` back into
         `docker/proxmox/docker-compose.yml`'s `FORGE_VERSION:` line —
         the import step picks the Forge version from the upstream zip,
         and these two values MUST match (itzg installs the loader
         specified by FORGE_VERSION; packwiz materializes mods that
         expect the loader version in pack.toml's [versions] block).
       7. `packwiz refresh` to regenerate index.toml.
       8. Print `git status` so the operator sees what's about to be
         committed and pushed.

    The script does NOT commit or push — review the diff first.

.PARAMETER PackZip
    Path to the downloaded Craft to Exile 2 CurseForge zip. Grab the
    latest from https://www.curseforge.com/minecraft/modpacks/craft-to-exile-2
    (Files tab → choose a version → manual download). The file naming
    pattern is typically `Craft+To+Exile+2-<version>.zip`.

.PARAMETER PackwizDir
    Path to the packwiz manifest directory. Defaults to `packwiz/` at
    the repo root (resolved relative to this script).

.PARAMETER CurseForgeApiKey
    Optional. CurseForge API key from https://console.curseforge.com/.
    If omitted, packwiz falls back to the public CFCore proxy. Setting
    it avoids rate limits on large packs and removes a third-party hop.
    Can also be supplied via the CURSEFORGE_API_KEY environment variable.

.PARAMETER YesAllPrompts
    Forward `-y` to every packwiz invocation. Useful in CI; in normal
    interactive use, leave this off so packwiz can prompt on ambiguous
    search results.

.EXAMPLE
    ./infra/azure/scripts/import-curseforge-pack.ps1 -PackZip 'C:\Downloads\Craft+To+Exile+2-0.4.0.zip'

.EXAMPLE
    # Non-interactive (CI-style):
    $env:CURSEFORGE_API_KEY = '...'
    ./infra/azure/scripts/import-curseforge-pack.ps1 -PackZip ./pack.zip -YesAllPrompts

.NOTES
    `packwiz` CLI must be on PATH. Install with:
        go install github.com/packwiz/packwiz@latest
    (Go 1.21+ required; the resulting binary lands in `%GOPATH%\bin`,
     which is usually already on PATH after a default Go install.)

    Prebuilt binaries are also published as GitHub Actions artifacts:
        https://nightly.link/packwiz/packwiz/workflows/go/main
    These are the same binaries PR 4's daily update workflow uses.
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

# The three server-only overlay mods, in the exact form `packwiz` should
# re-add them after the import wipes everything. Update these URLs in
# this script when bumping the overlay versions; keep them in lockstep
# with the .pw.toml content under packwiz/mods/.
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

# ─── Sanity checks ──────────────────────────────────────────────────────────
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

# ─── Forward CF API key to packwiz ──────────────────────────────────────────
if ($CurseForgeApiKey) {
    # packwiz reads this env var when adding/installing CF mods. Setting it
    # only for the duration of this script so we don't pollute the parent
    # shell's environment.
    $env:CURSEFORGE_API_KEY = $CurseForgeApiKey
    Write-Information 'CURSEFORGE_API_KEY set for this process.'
} else {
    Write-Warning 'No CurseForge API key — packwiz will use the public CFCore proxy. Subject to rate limits on large packs.'
}

$yesArgs = @()
if ($YesAllPrompts) { $yesArgs = @('-y') }

Push-Location $PackwizDir
try {
    # ─── 1. Snapshot the existing overlay metadata files ────────────────────
    # We re-add them by URL/project-id after the import, so we don't strictly
    # need the snapshot for correctness — but having it on disk under
    # `.import-staging/` is a useful audit trail (and lets the operator
    # diff the new files against the old to spot accidental version drift).
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

    # ─── 2. Run packwiz curseforge import ───────────────────────────────────
    # `-r` (reinit) lets it overwrite the existing pack.toml without prompting.
    Write-Information ''
    Write-Information '── packwiz curseforge import ──'
    & packwiz curseforge import @yesArgs $PackZip
    if ($LASTEXITCODE -ne 0) {
        throw "packwiz curseforge import failed (exit $LASTEXITCODE)."
    }

    # ─── 3. Re-add the three overlay mods ───────────────────────────────────
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

    # ─── 4. Mark overlay mods side="server" ─────────────────────────────────
    # packwiz writes side="both" by default. The three overlays are
    # explicitly server-only — flipping the side prevents PR 2's
    # publish flow from bundling them into the client zip.
    foreach ($mod in $OverlayMods) {
        $modFile = Join-Path $PackwizDir "mods\$($mod.Name).pw.toml"
        if (-not (Test-Path -LiteralPath $modFile)) {
            throw "Expected $modFile after re-add, but it's missing."
        }
        $content = Get-Content -Raw -LiteralPath $modFile
        # Match either `side = "both"` or `side = "client"` (defensive — packwiz
        # could theoretically pick either default depending on the project
        # metadata) and rewrite to `side = "server"`. The pattern intentionally
        # stops at the closing quote — it does NOT consume any trailing
        # whitespace or the line terminator, which keeps blank lines in the
        # TOML file intact (a $-anchored variant would eat the CRLF on Windows
        # since \s includes \r and \n).
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

    # ─── 5. Cross-check Forge version with docker/proxmox/docker-compose.yml ───
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

    # ─── 6. Refresh the index ───────────────────────────────────────────────
    Write-Information ''
    Write-Information '── packwiz refresh ──'
    & packwiz refresh
    if ($LASTEXITCODE -ne 0) {
        throw "packwiz refresh failed (exit $LASTEXITCODE)."
    }
}
finally {
    Pop-Location
}

# ─── 7. Show what changed ──────────────────────────────────────────────────
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
