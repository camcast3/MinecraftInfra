#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$manifestPath = Join-Path $PSScriptRoot 'compatibility-paths.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

& (Join-Path $PSScriptRoot 'Sync-CompatibilityPaths.ps1')

foreach ($mapping in @($manifest.copies)) {
    if ($mapping.ownerPath -match '^(?:old)(?:/|$)' -or
        $mapping.compatibilityPath -match '^(?:old)(?:/|$)' -or
        $mapping.ownerPath -eq 'admin_compose.yml' -or
        $mapping.compatibilityPath -eq 'admin_compose.yml') {
        throw "Archived content must not participate in layout migration."
    }
    if ([string]::IsNullOrWhiteSpace([string] $mapping.gate)) {
        throw "Every compatibility copy requires an explicit deprecation gate."
    }
}

foreach ($wrapper in @($manifest.wrappers)) {
    $compatibility = Join-Path $repositoryRoot $wrapper.compatibilityPath
    $owner = Join-Path $repositoryRoot $wrapper.ownerPath
    if (-not (Test-Path -LiteralPath $compatibility -PathType Leaf) -or
        -not (Test-Path -LiteralPath $owner -PathType Leaf)) {
        throw "Wrapper mapping is incomplete: $($wrapper.compatibilityPath) -> $($wrapper.ownerPath)"
    }
    $wrapperText = Get-Content -LiteralPath $compatibility -Raw -Encoding UTF8
    $ownerLeaf = Split-Path -Leaf $wrapper.ownerPath
    if (-not $wrapperText.Contains($ownerLeaf) -or
        -not $wrapperText.Contains('tools')) {
        throw "Compatibility wrapper does not forward to its owner: $($wrapper.compatibilityPath)"
    }
}

$requiredWorkflowPairs = [ordered]@{
    '.github/workflows/deploy-azure.yml' = @('infra/azure/**', 'platform/azure/**')
    '.github/workflows/release-nz.yml' = @('client/**', 'games/minecraft/client/**')
    '.github/workflows/test-nz-e2e.yml' = @('client/**', 'games/minecraft/client/**')
    '.github/workflows/validate-game-contracts.yml' = @('contracts/**', 'platform/contracts/**')
    '.github/workflows/validate-azure-edge.yml' = @('docker/azure/**', 'platform/azure/edge/**')
    '.github/workflows/validate-multigame-rollout.yml' = @('scripts/tests/**', 'tools/validation/**')
    '.github/workflows/validate-shared-access.yml' = @('docker/shared/**', 'games/minecraft/shared/**')
}
foreach ($entry in $requiredWorkflowPairs.GetEnumerator()) {
    $workflow = Get-Content -LiteralPath (Join-Path $repositoryRoot $entry.Key) -Raw
    foreach ($filter in $entry.Value) {
        if (-not $workflow.Contains($filter)) {
            throw "$($entry.Key) is missing dual-path workflow filter '$filter'."
        }
    }
}

$portainerPaths = @(
    'docker/proxmox/docker-compose.yml',
    'docker/palworld/docker-compose.yml',
    'docker/windrose/docker-compose.yml'
)
foreach ($relative in $portainerPaths) {
    $contracts = Get-ChildItem (Join-Path $repositoryRoot 'platform/contracts/games') -Filter '*.json'
    if (-not ($contracts | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw).Contains($relative)
    })) {
        throw "No canonical contract preserves live Portainer path '$relative'."
    }
}

$installScript = Get-Content -LiteralPath (
    Join-Path $repositoryRoot 'games/minecraft/client/scripts/install.ps1'
) -Raw
if (-not $installScript.Contains(
    'https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/nz-release.json'
)) {
    throw 'The released nz-latest metadata URL changed during layout migration.'
}

$composeFiles = @(
    'games/minecraft/c2e2/docker-compose.yml',
    'games/palworld/docker-compose.yml',
    'games/windrose/docker-compose.yml',
    'platform/azure/edge/docker-compose.yml'
)
foreach ($relative in $composeFiles) {
    $text = Get-Content -LiteralPath (Join-Path $repositoryRoot $relative) -Raw
    if ($text -match '(?m)^name:\s*') {
        throw "$relative introduces an explicit Compose project name during migration."
    }
}

$azureMain = Get-Content -LiteralPath (
    Join-Path $repositoryRoot 'platform/azure/iac/main.bicep'
) -Raw
foreach ($resourceName in @('rg-minecraft-prod', 'vm-minecraft-prod')) {
    $allRepositoryText = Get-Content -LiteralPath (
        Join-Path $repositoryRoot '.github/workflows/deploy-azure.yml'
    ) -Raw
    if (-not $allRepositoryText.Contains($resourceName)) {
        throw "Azure deployment resource name '$resourceName' changed or disappeared."
    }
}
if ([string]::IsNullOrWhiteSpace($azureMain)) {
    throw 'Canonical Azure Bicep entry point is empty.'
}

$linkedDocs = @(
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'README.md')
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'games') -Filter '*.md' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'platform') -Filter '*.md' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tools') -Filter '*.md' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'ops') -Filter '*.md' -File -Recurse
)
foreach ($document in $linkedDocs) {
    $content = Get-Content -LiteralPath $document.FullName -Raw
    foreach ($match in [regex]::Matches($content, '\[[^\]]+\]\((?<target>[^)]+)\)')) {
        $target = $match.Groups['target'].Value.Trim()
        if ($target -match '^(?:https?://|mailto:|#)') {
            continue
        }
        $pathOnly = ($target -split '[?#]', 2)[0]
        $resolved = if ($pathOnly.StartsWith('/')) {
            Join-Path $repositoryRoot $pathOnly.TrimStart('/')
        } else {
            Join-Path $document.DirectoryName $pathOnly
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            $relativeDocument = [System.IO.Path]::GetRelativePath(
                $repositoryRoot,
                $document.FullName
            ).Replace('\', '/')
            throw "Broken repository-document link in ${relativeDocument}: $target"
        }
    }
}

Write-Host 'Repository ownership, compatibility, workflow, release, Compose, and Azure path checks passed.'
