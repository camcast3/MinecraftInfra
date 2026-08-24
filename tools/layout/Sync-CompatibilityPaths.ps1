#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Write')]
    [switch] $Write,

    [Parameter(ParameterSetName = 'Bootstrap')]
    [switch] $Bootstrap,

    [string] $ManifestPath = (Join-Path $PSScriptRoot 'compatibility-paths.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', '..')
)
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

if ($manifest.schemaVersion -ne 1) {
    throw "Unsupported compatibility manifest schema: $($manifest.schemaVersion)"
}

function Test-Excluded {
    param(
        [string] $RelativePath,
        [object[]] $Patterns
    )

    $normalized = $RelativePath.Replace('\', '/')
    foreach ($pattern in @($Patterns)) {
        if ($normalized -like [string] $pattern) {
            return $true
        }
    }
    return $false
}

function Get-RelativeFiles {
    param(
        [string] $Root,
        [object[]] $Exclude
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse |
            ForEach-Object {
                [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
            } |
            Where-Object { -not (Test-Excluded -RelativePath $_ -Patterns $Exclude) } |
            Sort-Object
    )
}

function Copy-ExactFile {
    param(
        [string] $Source,
        [string] $Destination
    )

    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes(
        $Destination,
        [System.IO.File]::ReadAllBytes($Source)
    )
}

function Sync-Directory {
    param(
        [string] $Source,
        [string] $Destination,
        [object[]] $Exclude,
        [switch] $RemoveExtra
    )

    $sourceFiles = @(Get-RelativeFiles -Root $Source -Exclude $Exclude)
    if ($RemoveExtra) {
        $destinationFiles = @(Get-RelativeFiles -Root $Destination -Exclude $Exclude)
        foreach ($relative in @($destinationFiles | Where-Object {
            $_ -notin $sourceFiles
        })) {
            Remove-Item -LiteralPath (Join-Path $Destination $relative) -Force
        }
    }

    foreach ($relative in $sourceFiles) {
        Copy-ExactFile `
            -Source (Join-Path $Source $relative) `
            -Destination (Join-Path $Destination $relative)
    }
}

function Assert-EqualFile {
    param(
        [string] $Owner,
        [string] $Compatibility,
        [string] $Label
    )

    if (-not (Test-Path -LiteralPath $Owner -PathType Leaf)) {
        throw "Owner file is missing for ${Label}: $Owner"
    }
    if (-not (Test-Path -LiteralPath $Compatibility -PathType Leaf)) {
        throw "Compatibility file is missing for ${Label}: $Compatibility"
    }
    $ownerHash = (Get-FileHash -LiteralPath $Owner -Algorithm SHA256).Hash
    $compatibilityHash = (Get-FileHash -LiteralPath $Compatibility -Algorithm SHA256).Hash
    if ($ownerHash -cne $compatibilityHash) {
        throw "Compatibility file differs from owner source: $Label. Run tools/layout/Sync-CompatibilityPaths.ps1 -Write."
    }
}

foreach ($mapping in @($manifest.copies)) {
    $owner = Join-Path $repositoryRoot $mapping.ownerPath
    $compatibility = Join-Path $repositoryRoot $mapping.compatibilityPath
    $excludeProperty = $mapping.PSObject.Properties['exclude']
    $exclude = if ($null -eq $excludeProperty) {
        @()
    } else {
        @($excludeProperty.Value)
    }

    if ($Bootstrap) {
        if ($mapping.kind -eq 'file') {
            Copy-ExactFile -Source $compatibility -Destination $owner
        } else {
            Sync-Directory -Source $compatibility -Destination $owner -Exclude $exclude
        }
        Write-Host "BOOTSTRAP: $($mapping.compatibilityPath) -> $($mapping.ownerPath)"
        continue
    }

    if ($Write) {
        if ($mapping.kind -eq 'file') {
            Copy-ExactFile -Source $owner -Destination $compatibility
        } else {
            Sync-Directory -Source $owner -Destination $compatibility `
                -Exclude $exclude -RemoveExtra
        }
        Write-Host "SYNC: $($mapping.ownerPath) -> $($mapping.compatibilityPath)"
        continue
    }

    if ($mapping.kind -eq 'file') {
        Assert-EqualFile -Owner $owner -Compatibility $compatibility `
            -Label "$($mapping.ownerPath) -> $($mapping.compatibilityPath)"
        continue
    }

    $ownerFiles = @(Get-RelativeFiles -Root $owner -Exclude $exclude)
    $compatibilityFiles = @(Get-RelativeFiles -Root $compatibility -Exclude $exclude)
    $difference = @(Compare-Object $ownerFiles $compatibilityFiles)
    if ($difference.Count -gt 0) {
        $details = ($difference | ForEach-Object {
            "$($_.SideIndicator) $($_.InputObject)"
        }) -join '; '
        throw "Compatibility directory file set differs for $($mapping.ownerPath): $details"
    }
    foreach ($relative in $ownerFiles) {
        Assert-EqualFile `
            -Owner (Join-Path $owner $relative) `
            -Compatibility (Join-Path $compatibility $relative) `
            -Label "$($mapping.ownerPath)/$relative"
    }
}

if (-not $Write -and -not $Bootstrap) {
    Write-Host "All $(@($manifest.copies).Count) compatibility copy mappings are byte-identical."
}
