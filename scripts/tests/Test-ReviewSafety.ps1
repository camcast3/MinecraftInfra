#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if (-not $root) { throw 'Could not resolve repository root.' }

function Read-RepoFile([string] $RelativePath) {
    Get-Content -LiteralPath (Join-Path $root $RelativePath) -Raw -Encoding UTF8
}

function Assert-Match([string] $Text, [string] $Pattern, [string] $Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

function Assert-NoMatch([string] $Text, [string] $Pattern, [string] $Message) {
    if ($Text -match $Pattern) { throw $Message }
}

$palworld = Read-RepoFile 'games/palworld/docker-compose.yml'
Assert-Match $palworld '(?ms)palworld-init:.*?user:\s*"0:0".*?condition:\s*service_completed_successfully' `
    'Palworld must initialize volume ownership as root before game startup.'
Assert-Match $palworld '(?ms)palworld:.*?user:\s*"user:usergroup"' `
    'Palworld game process must run as the image non-root user.'
Assert-NoMatch $palworld '(?m)^\s*sudo\s+chown\b' `
    'Palworld startup must not use sudo under no-new-privileges.'

$promotionWorkflow = Read-RepoFile '.github/workflows/promote-prism-pack.yml'
Assert-Match $promotionWorkflow 'test-c2e2-backend\.ps1' `
    'Stable promotion must verify the private C2E2 backend directly.'

$promotionScript = Read-RepoFile 'infra/azure/scripts/promote-prism-pack.ps1'
Assert-Match $promotionScript '\$PSNativeCommandUseErrorActionPreference\s*=\s*\$true' `
    'Promotion must make native command failures terminating.'
Assert-Match $promotionScript 'Get-FileHash.+SHA256' `
    'Promotion must hash the immutable zip before changing stable pointers.'
Assert-Match $promotionScript '\[switch\]\s*\$AllowDowngrade' `
    'Promotion must provide an explicit complete-manifest rollback mode.'

$runbook = Read-RepoFile 'ops/publish-runbook.md'
Assert-Match $runbook 'promote-prism-pack\.ps1 -AllowDowngrade' `
    'Rollback documentation must use the validated complete manifest.'

$packwizReadme = Read-RepoFile 'packwiz/README.md'
Assert-Match $packwizReadme '-LocalOutDir' `
    'Local package testing must explicitly enable no-side-effect local mode.'
Assert-Match $packwizReadme '-LocalBaseUrl' `
    'Local package testing must supply its local manifest base URL.'

$mainBicep = Read-RepoFile 'platform/azure/iac/main.bicep'
Assert-NoMatch $mainBicep 'palworldBackupSpObjectId string\s*=\s*proxmoxSpObjectId' `
    'Palworld must never inherit the C2E2 backup principal.'
Assert-NoMatch $mainBicep 'windroseBackupSpObjectId string\s*=\s*proxmoxSpObjectId' `
    'Windrose must never inherit the C2E2 backup principal.'

$backupModule = Read-RepoFile 'platform/azure/iac/modules/backup-storage.bicep'
Assert-NoMatch $backupModule 'guid\([^\r\n]*writerPrincipalId' `
    'Changing a backup writer must fail closed instead of leaving a second role assignment.'

$deployWorkflow = Read-RepoFile '.github/workflows/deploy-azure.yml'
Assert-Match $deployWorkflow "ref:\s*\$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.ref \|\| github\.sha \}\}" `
    'Validation and deployment must use the same requested ref.'
Assert-Match $deployWorkflow 'DEPLOY_AZURE_OK' `
    'Azure deployment must require a remote success marker.'

$releaseWorkflow = Read-RepoFile '.github/workflows/release-nz.yml'
Assert-NoMatch $releaseWorkflow 'gh release delete nz-latest' `
    'The production nz alias must not be deleted before replacement assets exist.'
Assert-Match $releaseWorkflow '(?ms)gh release upload nz-latest.+nz-release\.json.+--clobber' `
    'The nz alias must update its manifest through a non-destructive upload.'

$corpus = Read-RepoFile 'games/minecraft/client/scripts/build-instance-corpus.ps1'
Assert-Match $corpus 'unsupported raw/binary file' `
    'Unknown raw files must be excluded from the sanitized corpus.'
Assert-Match $corpus 'Redact-StructuredValue' `
    'Structured credentials must be recursively redacted.'

Write-Host 'Review-safety regression checks passed.'
