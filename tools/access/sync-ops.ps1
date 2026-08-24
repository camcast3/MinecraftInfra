[CmdletBinding()]
param(
    [string]$WhitelistPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', '..', 'games', 'minecraft', 'shared', 'whitelist.json'
    ),
    [string]$OpsPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', '..', 'games', 'minecraft', 'shared', 'ops.json'
    ),
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WhitelistPath = [System.IO.Path]::GetFullPath($WhitelistPath)
$OpsPath = [System.IO.Path]::GetFullPath($OpsPath)

if (-not (Test-Path -LiteralPath $WhitelistPath -PathType Leaf)) {
    throw "Whitelist file not found: $WhitelistPath"
}

try {
    $whitelist = @(Get-Content -Raw -LiteralPath $WhitelistPath -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop)
} catch {
    throw "Could not parse whitelist JSON at '$WhitelistPath': $($_.Exception.Message)"
}

$seenUuids = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$operators = @(
    foreach ($entry in $whitelist) {
        if ($null -eq $entry) {
            throw "Whitelist contains a null entry."
        }

        $uuidProperty = $entry.PSObject.Properties['uuid']
        $nameProperty = $entry.PSObject.Properties['name']
        if ($null -eq $uuidProperty -or
            $uuidProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($uuidProperty.Value)) {
            throw "Every whitelist entry must contain a non-empty string 'uuid'."
        }
        if ($null -eq $nameProperty -or
            $nameProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($nameProperty.Value)) {
            throw "Whitelist entry '$($uuidProperty.Value)' must contain a non-empty string 'name'."
        }

        $parsedUuid = [Guid]::Empty
        if (-not [Guid]::TryParseExact($uuidProperty.Value, 'D', [ref]$parsedUuid)) {
            throw "Whitelist UUID '$($uuidProperty.Value)' is not a dashed UUID."
        }
        if (-not $seenUuids.Add($uuidProperty.Value)) {
            throw "Whitelist UUID '$($uuidProperty.Value)' is duplicated."
        }

        [pscustomobject][ordered]@{
            uuid                = $uuidProperty.Value
            name                = $nameProperty.Value
            level               = 3
            bypassesPlayerLimit = $false
        }
    }
)

$expected = ConvertTo-Json -InputObject @($operators) -Depth 3
$expected = ($expected -replace "`r`n", "`n") + "`n"

if ($Check) {
    if (-not (Test-Path -LiteralPath $OpsPath -PathType Leaf)) {
        throw "Generated ops file not found: $OpsPath. Run tools/access/sync-ops.ps1."
    }

    $actual = (Get-Content -Raw -LiteralPath $OpsPath -Encoding UTF8) -replace "`r`n", "`n"
    if ($actual -cne $expected) {
        throw "ops.json differs from whitelist.json. Run tools/access/sync-ops.ps1, sync compatibility paths, and commit both results."
    }

    Write-Host "ops.json matches all $($operators.Count) whitelist entries."
    return
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($OpsPath, $expected, $utf8NoBom)
Write-Host "Generated $OpsPath with $($operators.Count) level-3 operators."

$repositoryRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if (-not $repositoryRoot) {
    throw 'Could not resolve the repository root for compatibility synchronization.'
}
& (Join-Path $repositoryRoot 'tools/layout/Sync-CompatibilityPaths.ps1') -Write
