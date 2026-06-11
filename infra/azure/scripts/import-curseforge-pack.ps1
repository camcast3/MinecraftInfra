#requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap or refresh the `packwiz/` manifest by importing the Craft to
    Exile 2 CurseForge server zip, then folding the three server-only
    overlay mods (spark, Proxy-Compatible-Forge, minecraft-prometheus-exporter)
    back on top of the freshly imported pack.

.DESCRIPTION
    `packwiz curseforge import` recreates pack.toml + index.toml + mods/ from
    scratch — it does NOT merge into an existing pack. So every C2E2 upstream
    bump would clobber the three server-only overlay mods we layer on top.
    This helper:

      1. Snapshots the existing overlay `.pw.toml` files under
         `packwiz/.import-staging/` (audit trail + restore source).
      2. Runs `packwiz curseforge import <PackZip>` against `packwiz/`,
         which replaces pack.toml + index.toml + mods/*.pw.toml.
      3. Copies the snapshotted overlay files back into `packwiz/mods/` so
         any version bumps you've made via `packwiz update` or by hand-
         editing the .pw.toml survive the import.
      4. Defensively pins `side = "server"` on each overlay so PR 2's
         client zip publisher will exclude them.
      5. Syncs the Forge loader version from `packwiz/pack.toml` into
         `docker/proxmox/docker-compose.yml`'s `FORGE_VERSION:` line —
         these two MUST match (itzg installs the loader specified by
         FORGE_VERSION; packwiz materializes mods compiled against the
         loader version in pack.toml's [versions] block).
      6. Runs `packwiz refresh` to regenerate index.toml hashes.
      7. Prints a focused `git status` so the operator can review the
         diff before committing.

    The script does NOT commit, push, or bump `PACKWIZ_COMMIT_SHA` in
    `docker/proxmox/.env` — review the diff first, then handle those
    steps manually (PR 2's publish flow will eventually automate the
    SHA bump).

.PARAMETER PackZip
    Path to the downloaded Craft to Exile 2 CurseForge zip. Grab the
    latest from
        https://www.curseforge.com/minecraft/modpacks/craft-to-exile-2
    (Files tab → choose a version → manual download). Filename is
    typically `Craft+To+Exile+2-<version>.zip`.

.PARAMETER PackwizDir
    Path to the packwiz manifest directory. Defaults to `packwiz/` at the
    repo root, resolved relative to this script.

.PARAMETER ComposeFile
    Path to the Proxmox compose file whose `FORGE_VERSION:` line should
    be kept in sync with `pack.toml`. Defaults to
    `docker/proxmox/docker-compose.yml` at the repo root.

.PARAMETER CurseForgeApiKey
    CurseForge API key from https://console.curseforge.com/. Falls back
    to `$env:CURSEFORGE_API_KEY` if omitted. Setting it removes a
    third-party hop and avoids rate limits on large pack imports.

.PARAMETER YesAllPrompts
    Forward `-y` to every `packwiz` invocation. Useful in CI; leave off
    for interactive runs so packwiz can prompt on ambiguous results.

.EXAMPLE
    ./infra/azure/scripts/import-curseforge-pack.ps1 -PackZip 'C:\Downloads\Craft+To+Exile+2-0.4.0.zip'

.EXAMPLE
    # Non-interactive (CI / scripted bump):
    $env:CURSEFORGE_API_KEY = '...'
    ./infra/azure/scripts/import-curseforge-pack.ps1 -PackZip ./pack.zip -YesAllPrompts

.NOTES
    The `packwiz` CLI must be on PATH. Install with:
        go install github.com/packwiz/packwiz@latest
    (Go 1.21+; the resulting binary lands in `$env:GOPATH\bin`, which is
    on PATH after a default Go install.)

    Prebuilt nightlies are also published as GitHub Actions artifacts:
        https://nightly.link/packwiz/packwiz/workflows/go/main
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackZip,

    [string] $PackwizDir,

    [string] $ComposeFile,

    [string] $CurseForgeApiKey = $env:CURSEFORGE_API_KEY,

    [switch] $YesAllPrompts
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Write-Step([string] $Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string] $Message) {
    Write-Host "    [ok] $Message" -ForegroundColor Green
}

function Resolve-FullPath([string] $Path) {
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

# Server-only overlay mods. The script snapshots whichever of these is
# already in packwiz/mods/ before the import, then restores them on top
# of the imported pack. Adding/removing overlays is a one-line change
# here.
$OverlayModNames = @(
    'spark',
    'proxy-compatible-forge',
    'minecraft-prometheus-exporter'
)

# ─── Preflight ──────────────────────────────────────────────────────────
$packwiz = Get-Command packwiz -ErrorAction SilentlyContinue
if (-not $packwiz) {
    throw @'
packwiz CLI not found on PATH. Install with:
    go install github.com/packwiz/packwiz@latest
or grab a prebuilt binary from
    https://nightly.link/packwiz/packwiz/workflows/go/main
and put it on PATH.
'@
}
Write-Information "Using packwiz at: $($packwiz.Source)"

if (-not (Test-Path -LiteralPath $PackZip -PathType Leaf)) {
    throw "PackZip not found: $PackZip"
}
$PackZip = Resolve-FullPath $PackZip

if (-not $PackwizDir) {
    # Script lives at infra/azure/scripts/, so packwiz/ is three up.
    $PackwizDir = Join-Path $PSScriptRoot '..\..\..\packwiz'
}
if (-not (Test-Path -LiteralPath $PackwizDir -PathType Container)) {
    throw "PackwizDir not found: $PackwizDir`nPass -PackwizDir or run from a checkout that has packwiz/ committed."
}
$PackwizDir = Resolve-FullPath $PackwizDir
$repoRoot   = Resolve-FullPath (Join-Path $PackwizDir '..')

if (-not $ComposeFile) {
    $ComposeFile = Join-Path $repoRoot 'docker\proxmox\docker-compose.yml'
}
$ComposeFileExists = Test-Path -LiteralPath $ComposeFile -PathType Leaf
if ($ComposeFileExists) {
    $ComposeFile = Resolve-FullPath $ComposeFile
}

Write-Information "Working directory: $PackwizDir"
Write-Information "CurseForge zip   : $PackZip"
Write-Information "Compose file     : $(if ($ComposeFileExists) { $ComposeFile } else { "$ComposeFile (not found — FORGE_VERSION sync will be skipped)" })"

# ─── CurseForge API key forwarding ──────────────────────────────────────
# packwiz reads CURSEFORGE_API_KEY when adding CF mods. Set it only for
# the duration of this script so we don't pollute the parent shell.
if ($CurseForgeApiKey) {
    $env:CURSEFORGE_API_KEY = $CurseForgeApiKey
    Write-Information 'CURSEFORGE_API_KEY set for this process.'
} else {
    Write-Warning 'No CurseForge API key — packwiz will use the public CFCore proxy. Subject to rate limits on large pack imports.'
}

$yesArgs = @()
if ($YesAllPrompts) { $yesArgs = @('-y') }

Push-Location $PackwizDir
try {
    # ─── 1. Snapshot overlay metadata ───────────────────────────────────
    $stagingDir = Join-Path $PackwizDir '.import-staging'
    if (Test-Path -LiteralPath $stagingDir) { Remove-Item -Recurse -Force -LiteralPath $stagingDir }
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    Write-Step 'Snapshotting overlay mod metadata'
    $snapshotted = @()
    foreach ($name in $OverlayModNames) {
        $src = Join-Path $PackwizDir "mods\$name.pw.toml"
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            Copy-Item -LiteralPath $src -Destination $stagingDir
            Write-Ok "snapshotted mods\$name.pw.toml"
            $snapshotted += $name
        } else {
            Write-Warning "mods\$name.pw.toml not present before import — overlay will be MISSING from the resulting pack. Add it manually after the script finishes."
        }
    }

    # ─── 2. packwiz curseforge import ───────────────────────────────────
    Write-Step "packwiz curseforge import $PackZip"
    & packwiz curseforge import @yesArgs $PackZip
    if ($LASTEXITCODE -ne 0) {
        throw "packwiz curseforge import failed (exit $LASTEXITCODE)."
    }

    # ─── 3. Restore overlay metadata ────────────────────────────────────
    # Copy the snapshots back unchanged. This preserves whatever upstream
    # version + hash they had pre-import, so an upstream-only C2E2 bump
    # doesn't accidentally also bump an overlay.
    Write-Step 'Restoring overlay mod metadata'
    $modsDir = Join-Path $PackwizDir 'mods'
    if (-not (Test-Path -LiteralPath $modsDir -PathType Container)) {
        # `packwiz curseforge import` should create this — if it didn't,
        # something went wrong above and `packwiz refresh` later would
        # silently produce an empty index.
        throw "Expected mods/ directory after import but it's missing: $modsDir"
    }
    foreach ($name in $snapshotted) {
        $snapshot = Join-Path $stagingDir "$name.pw.toml"
        $dest     = Join-Path $modsDir "$name.pw.toml"
        Copy-Item -LiteralPath $snapshot -Destination $dest -Force
        Write-Ok "restored mods\$name.pw.toml"
    }

    # ─── 4. Pin overlays to side="server" ───────────────────────────────
    # Defensive: the snapshot SHOULD already be side="server", but if the
    # overlay file was generated by `packwiz add` (defaults to side="both")
    # and never hand-corrected, fix it now so PR 2's client-zip publisher
    # excludes it.
    Write-Step 'Enforcing side="server" on overlay mods'
    foreach ($name in $snapshotted) {
        $modFile = Join-Path $modsDir "$name.pw.toml"
        if (-not (Test-Path -LiteralPath $modFile -PathType Leaf)) { continue }
        $content = Get-Content -Raw -LiteralPath $modFile
        # Match only `side = "both"` or `side = "client"`; leave anything
        # already `server` alone. Pattern stops at the closing quote so it
        # doesn't eat the line terminator (a $-anchored variant would
        # consume CRLF on Windows since \s includes \r\n).
        $rewritten = [regex]::Replace(
            $content,
            '(?m)^side[ \t]*=[ \t]*"(both|client)"',
            'side = "server"'
        )
        if ($rewritten -ne $content) {
            # Preserve the file's existing trailing-newline state so the
            # index.toml hash only flips when something semantic changed.
            Set-Content -LiteralPath $modFile -Value $rewritten -NoNewline
            Write-Ok "${name}: side -> server"
        }
    }

    # ─── 5. Sync FORGE_VERSION → docker-compose.yml ─────────────────────
    if (-not $ComposeFileExists) {
        Write-Warning "Compose file not found at $ComposeFile — skipping FORGE_VERSION sync. Set it manually to match packwiz/pack.toml's forge=... value."
    } else {
        $packToml = Join-Path $PackwizDir 'pack.toml'
        $packForgeMatch = (Get-Content -Raw -LiteralPath $packToml) |
            Select-String -Pattern '(?m)^forge\s*=\s*"([^"]+)"'
        if (-not $packForgeMatch) {
            Write-Warning 'Could not detect `forge = "..."` in packwiz/pack.toml — skipping FORGE_VERSION sync.'
        } else {
            $packForge      = $packForgeMatch.Matches[0].Groups[1].Value
            $composeContent = Get-Content -Raw -LiteralPath $ComposeFile
            $composeForgeMatch = $composeContent |
                Select-String -Pattern '(?m)^\s*FORGE_VERSION:\s*"([^"]+)"'
            if (-not $composeForgeMatch) {
                Write-Warning "No `FORGE_VERSION:` line found in $ComposeFile — please add it manually with value `"$packForge`"."
            } else {
                $composeForge = $composeForgeMatch.Matches[0].Groups[1].Value
                if ($composeForge -eq $packForge) {
                    Write-Information "FORGE_VERSION already matches packwiz: $packForge"
                } else {
                    Write-Step "Updating FORGE_VERSION in compose: $composeForge -> $packForge"
                    $newCompose = [regex]::Replace(
                        $composeContent,
                        '(?m)(^\s*FORGE_VERSION:\s*")[^"]+(")',
                        "`${1}$packForge`${2}"
                    )
                    Set-Content -LiteralPath $ComposeFile -Value $newCompose -NoNewline
                    Write-Ok "compose FORGE_VERSION = $packForge"
                }
            }
        }
    }

    # ─── 6. Refresh the index ───────────────────────────────────────────
    # packwiz refresh re-scans mods/ and rewrites index.toml's [[files]]
    # entries + hashes to match the on-disk .pw.toml content. Required
    # because steps 3 + 4 modified .pw.toml files behind packwiz's back.
    Write-Step 'packwiz refresh'
    & packwiz refresh
    if ($LASTEXITCODE -ne 0) {
        throw "packwiz refresh failed (exit $LASTEXITCODE)."
    }
}
finally {
    Pop-Location
}

# ─── 7. Show what changed ───────────────────────────────────────────────
$gitDir = & git -C $repoRoot rev-parse --git-dir 2>$null
if ($LASTEXITCODE -eq 0 -and $gitDir) {
    Write-Step 'git status (packwiz + compose)'
    $statusArgs = @('status', '--short', '--', $PackwizDir)
    if ($ComposeFileExists) { $statusArgs += $ComposeFile }
    & git -C $repoRoot @statusArgs
} else {
    Write-Information "Skipping git status — $repoRoot is not a git repository."
}

Write-Host ''
Write-Host @'
Done. Next steps:

  1. Review the diff:
         git -C <repo> diff -- packwiz/ docker/proxmox/docker-compose.yml
     Verify the new mods/*.pw.toml files don't include anything surprising
     and that FORGE_VERSION matches packwiz/pack.toml.

  2. Commit and push on your PR branch. Open a PR so CI can validate the
     packwiz manifest before it reaches production.

  3. After merge, bump PACKWIZ_COMMIT_SHA in docker/proxmox/.env to the
     merge commit SHA so the Proxmox stack pulls this pinned snapshot
     instead of main HEAD. PR 2 will automate this bump as part of the
     publish-prism-pack.ps1 flow; until then, do it manually:

         git -C <repo> rev-parse HEAD   # paste into PACKWIZ_COMMIT_SHA=
'@ -ForegroundColor Green
