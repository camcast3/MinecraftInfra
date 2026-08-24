#requires -Version 7.0
<#
.SYNOPSIS
    Build and test a sanitized, immutable corpus of local Prism instances.

.DESCRIPTION
    Discovery is read-only. A candidate is skipped if Prism/Minecraft is
    running, a NegativeZone lock/journal exists, the tree changes during the
    copy, or any reparse point or unreadable entry is found.

    Copies are written only under the ignored .artifacts directory by default.
    Personal/runtime data and credential-bearing paths are excluded. Text is
    redacted in memory before it is written to the corpus. The original
    instances are never changed and real packwiz/Minecraft processes are never
    launched.
#>

[CmdletBinding()]
param(
    [string[]] $InstancesRoot,
    [string] $ArtifactRoot,
    [switch] $SkipCompatibilityTests
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'Could not resolve the repository root.' }
$clientDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ArtifactRoot) {
    $ArtifactRoot = Join-Path $repoRoot '.artifacts\instance-corpus'
}
$ArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot)
$runRoot = Join-Path $ArtifactRoot ("run-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$snapshotRoot = Join-Path $runRoot 'snapshots'
$testTemp = Join-Path $runRoot 'test-work'

if (-not $InstancesRoot -or $InstancesRoot.Count -eq 0) {
    $InstancesRoot = @()
    if ($env:APPDATA) {
        $InstancesRoot += Join-Path $env:APPDATA 'PrismLauncher\instances'
    }
    if ($env:PRISM_INSTANCE_DIR) {
        $InstancesRoot += $env:PRISM_INSTANCE_DIR
    }
}
$InstancesRoot = @($InstancesRoot |
    Where-Object { $_ } |
    ForEach-Object { [IO.Path]::GetFullPath($_) } |
    Select-Object -Unique)

$excludedDirectoryNames = @(
    'logs', 'crash-reports', 'screenshots', 'saves', 'backups',
    'server-resource-packs', 'webcache', 'cache', '.cache'
)
$excludedFileNames = @(
    '.env', 'servers.dat', 'usercache.json', 'usernamecache.json',
    'launcher_accounts.json', 'accounts.json', 'realms_persistence.json',
    'known_hosts', 'knownkeys.txt', 'options.txt', 'optionsof.txt',
    'optionsshaders.txt'
)
$excludedExtensions = @(
    '.log', '.dmp', '.crash', '.pem', '.key', '.pfx', '.p12', '.token',
    '.credentials', '.db', '.sqlite', '.sqlite3', '.nbt'
)
$textExtensions = @(
    '.cfg', '.conf', '.json', '.json5', '.toml', '.yaml', '.yml', '.txt',
    '.properties', '.ini', '.xml', '.snbt', '.js', '.zs', '.mcmeta',
    '.html', '.css', '.md'
)
$safeBinaryExtensions = @(
    '.jar', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico'
)
$sensitiveKeyPattern = '(?i)^(access[_-]?token|refresh[_-]?token|oauth|authorization|password|passwd|secret|api[_-]?key|client[_-]?secret)$'

function Get-SHA256Text([string] $Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Test-ExcludedPath([string] $RelativePath) {
    $normalized = $RelativePath.Replace('/', '\').TrimStart('\')
    $segments = $normalized.Split('\', [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments) {
        if ($excludedDirectoryNames -contains $segment.ToLowerInvariant()) {
            return 'personal/runtime directory'
        }
    }
    $name = [IO.Path]::GetFileName($normalized).ToLowerInvariant()
    foreach ($sensitiveName in $excludedFileNames) {
        if ($name -eq $sensitiveName -or
            $name.StartsWith("$sensitiveName.", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("${sensitiveName}_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("${sensitiveName}-", [StringComparison]::OrdinalIgnoreCase)) {
            return 'credential/personal file'
        }
    }
    if ($name -like '.env.*') {
        return 'credential/personal file'
    }
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
    if ($excludedExtensions -contains $extension) {
        return 'credential/personal binary'
    }
    return $null
}

function Test-ExcludedFile([IO.FileInfo] $File, [string] $RelativePath) {
    $reason = Test-ExcludedPath $RelativePath
    if ($reason) {
        return $reason
    }
    if (($textExtensions -contains $File.Extension.ToLowerInvariant()) -and $File.Length -gt 16MB) {
        return 'oversized text not safely sanitizable'
    }
    $extension = $File.Extension.ToLowerInvariant()
    if (($textExtensions -notcontains $extension) -and
        ($safeBinaryExtensions -notcontains $extension)) {
        return 'unsupported raw/binary file'
    }
    return $null
}

function Redact-StructuredValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ([string]$key -match $sensitiveKeyPattern) {
                $Value[$key] = '<redacted>'
            } else {
                $Value[$key] = Redact-StructuredValue $Value[$key]
            }
        }
        return $Value
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        foreach ($property in @($Value.PSObject.Properties)) {
            if ($property.Name -match $sensitiveKeyPattern) {
                $property.Value = '<redacted>'
            } else {
                $property.Value = Redact-StructuredValue $property.Value
            }
        }
        return $Value
    }
    if (($Value -is [Collections.IEnumerable]) -and -not ($Value -is [string])) {
        return @($Value | ForEach-Object { Redact-StructuredValue $_ })
    }
    return $Value
}

function ConvertFrom-SafeTextBytes([byte[]] $Bytes) {
    $encodings = @(
        [Text.UTF8Encoding]::new($false, $true),
        [Text.UnicodeEncoding]::new($false, $true, $true),
        [Text.UnicodeEncoding]::new($true, $true, $true)
    )
    foreach ($encoding in $encodings) {
        try {
            return $encoding.GetString($Bytes)
        } catch {
            continue
        }
    }
    throw 'text file is not valid UTF-8 or UTF-16'
}

function Get-SanitizedBytes([IO.FileInfo] $File, [string] $RelativePath) {
    $bytes = [IO.File]::ReadAllBytes($File.FullName)
    $extension = $File.Extension.ToLowerInvariant()
    if ($textExtensions -notcontains $extension) {
        if ($safeBinaryExtensions -notcontains $extension) {
            throw "unsupported raw/binary file: $RelativePath"
        }
        return ,$bytes
    }

    try {
        $text = ConvertFrom-SafeTextBytes $bytes
    } catch {
        throw "unsafe undecodable text file: $RelativePath"
    }

    if ($extension -eq '.json') {
        try {
            $json = $text | ConvertFrom-Json -Depth 100
            $text = (Redact-StructuredValue $json) | ConvertTo-Json -Depth 100
        } catch {
            throw "invalid JSON cannot be safely sanitized: $RelativePath"
        }
    }

    if ($extension -ne '.json') {
        $text = [regex]::Replace(
            $text,
            '(?im)^(\s*["'']?(?:access[_-]?token|refresh[_-]?token|oauth|authorization|password|passwd|secret|api[_-]?key|client[_-]?secret)["'']?\s*[:=])\s*.*$',
            '$1<redacted>'
        )
    }
    $text = [regex]::Replace($text, '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer <redacted>')
    if ($env:USERPROFILE) {
        $text = $text.Replace($env:USERPROFILE, '<USERPROFILE>', [StringComparison]::OrdinalIgnoreCase)
    }
    if ($env:USERNAME) {
        $text = [regex]::Replace($text, "(?i)(?<![A-Za-z0-9])$([regex]::Escape($env:USERNAME))(?![A-Za-z0-9])", '<USER>')
    }
    if ($env:COMPUTERNAME) {
        $text = $text.Replace($env:COMPUTERNAME, '<COMPUTER>', [StringComparison]::OrdinalIgnoreCase)
    }
    if ($RelativePath -ieq 'instance.cfg') {
        $text = [regex]::Replace($text, '(?im)^name=.*$', 'name=Sanitized Corpus Instance')
        $text = [regex]::Replace($text, '(?im)^(lastLaunchTime|totalTimePlayed)=.*$', '$1=0')
    }
    $sanitized = [Text.UTF8Encoding]::new($false).GetBytes($text)
    [Array]::Clear($bytes, 0, $bytes.Length)
    return ,$sanitized
}

function Get-TreeInventory([string] $Path) {
    $rootItem = Get-Item -LiteralPath $Path -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "candidate root is a reparse point"
    }
    $items = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)
    $reparse = @($items | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    })
    if ($reparse.Count -gt 0) {
        throw "tree contains $($reparse.Count) reparse point(s)"
    }

    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $state = @{}
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Path, $file.FullName)
        $state[$relative] = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
    }
    return [pscustomobject]@{ Files = $files; State = $state }
}

function Assert-TreeUnchanged([string] $Path, [hashtable] $Before) {
    $after = Get-TreeInventory $Path
    if ($after.State.Count -ne $Before.Count) {
        throw "source tree changed during snapshot (file count)"
    }
    foreach ($entry in $Before.GetEnumerator()) {
        if (-not $after.State.ContainsKey($entry.Key) -or $after.State[$entry.Key] -ne $entry.Value) {
            throw "source tree changed during snapshot"
        }
    }
}

function Set-TreeReadOnly([string] $Path) {
    Get-ChildItem -LiteralPath $Path -File -Force -Recurse | ForEach-Object {
        $_.IsReadOnly = $true
    }
}

function Get-FreeBytes([string] $Path) {
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    return [IO.DriveInfo]::new($root).AvailableFreeSpace
}

New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
New-Item -ItemType Directory -Path $testTemp -Force | Out-Null

$activeProcesses = @(Get-Process -Name 'PrismLauncher', 'prismlauncher', 'java', 'javaw' -ErrorAction SilentlyContinue)
$candidates = @()
foreach ($root in $InstancesRoot) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        continue
    }
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop) {
        $dotMC = Join-Path $dir.FullName '.minecraft'
        if (Test-Path -LiteralPath $dotMC -PathType Container) {
            $candidates += $dir
        }
    }
}
$candidates = @($candidates | Sort-Object FullName -Unique)

$report = [ordered]@{
    schemaVersion = 1
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    completedAtUtc = ''
    artifactRoot = $runRoot
    productionDataLaunched = $false
    originalInstancesModified = $false
    candidates = @()
}

$copied = @()
$index = 0
foreach ($candidate in $candidates) {
    $index++
    $case = [ordered]@{
        displayName = $candidate.Name
        sourcePathHash = Get-SHA256Text $candidate.FullName
        status = 'pending'
        reason = ''
        snapshot = ''
        fileCount = 0
        bytes = 0
        excludedCount = 0
        compatibility = 'not-run'
    }
    $report.candidates += $case

    if ($activeProcesses.Count -gt 0) {
        $case.status = 'skipped'
        $case.reason = "launcher/game process active: $(@($activeProcesses.ProcessName | Sort-Object -Unique) -join ', ')"
        continue
    }

    $parent = $candidate.Parent.FullName
    $base = $candidate.Name
    $busyMarkers = @(
        (Join-Path $parent ".$base.nz-update.lock"),
        (Join-Path $parent ".$base.nz-transaction.lock"),
        (Join-Path $parent ".$base.nz-transaction.json")
    ) | Where-Object { Test-Path -LiteralPath $_ }
    if ($busyMarkers.Count -gt 0) {
        $case.status = 'skipped'
        $case.reason = 'NegativeZone lock or recovery journal exists'
        continue
    }

    $caseID = 'instance-{0:d3}' -f $index
    $snapshot = Join-Path $snapshotRoot $caseID
    $payload = Join-Path $snapshot 'payload'
    try {
        $inventory = Get-TreeInventory $candidate.FullName
        $includedBytes = 0L
        foreach ($file in $inventory.Files) {
            $relative = [IO.Path]::GetRelativePath($candidate.FullName, $file.FullName)
            if (-not (Test-ExcludedFile $file $relative)) {
                $includedBytes += $file.Length
            }
        }
        $multiplier = if ($SkipCompatibilityTests) { 2 } else { 6 }
        $needed = ($includedBytes * $multiplier) + 2GB
        if ((Get-FreeBytes $runRoot) -lt $needed) {
            throw "insufficient free disk for isolated snapshot/test (need about $([math]::Ceiling($needed / 1GB)) GiB)"
        }

        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        $fileManifest = [Collections.Generic.List[object]]::new()
        $exclusions = [Collections.Generic.List[object]]::new()
        foreach ($file in $inventory.Files) {
            $relative = [IO.Path]::GetRelativePath($candidate.FullName, $file.FullName)
            $excludeReason = Test-ExcludedFile $file $relative
            if ($excludeReason) {
                $exclusions.Add([ordered]@{
                    pathHash = Get-SHA256Text $relative
                    reason = $excludeReason
                })
                continue
            }

            $destination = Join-Path $payload $relative
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
            $bytes = Get-SanitizedBytes $file $relative
            try {
                [IO.File]::WriteAllBytes($destination, $bytes)
                $hash = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($bytes)
                ).ToLowerInvariant()
                $fileManifest.Add([ordered]@{
                    path = $relative.Replace('\', '/')
                    size = $bytes.Length
                    sha256 = $hash
                })
                $case.bytes += $bytes.Length
            } finally {
                [Array]::Clear($bytes, 0, $bytes.Length)
            }
        }

        Assert-TreeUnchanged $candidate.FullName $inventory.State
        $manifest = [ordered]@{
            schemaVersion = 1
            corpusID = $caseID
            sourcePathHash = $case.sourcePathHash
            sanitized = $true
            immutable = $true
            createdAtUtc = [DateTime]::UtcNow.ToString('o')
            files = $fileManifest
            exclusions = $exclusions
        }
        $fixture = [ordered]@{
            schemaVersion = 1
            corpusID = $caseID
            hasInstanceCfg = Test-Path -LiteralPath (Join-Path $payload 'instance.cfg')
            hasMMCPack = Test-Path -LiteralPath (Join-Path $payload 'mmc-pack.json')
            hasVersionMarker = Test-Path -LiteralPath (Join-Path $payload '.negativezone-version')
            fileCount = $fileManifest.Count
            bytes = $case.bytes
        }
        $manifestPath = Join-Path $snapshot 'manifest.json'
        $fixturePath = Join-Path $snapshot 'fixture.json'
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($fixturePath, ($fixture | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        Set-TreeReadOnly $payload
        (Get-Item -LiteralPath $manifestPath).IsReadOnly = $true
        (Get-Item -LiteralPath $fixturePath).IsReadOnly = $true

        $case.status = 'copied'
        $case.snapshot = $snapshot
        $case.fileCount = $fileManifest.Count
        $case.excludedCount = $exclusions.Count
        $copied += [pscustomobject]@{ Case = $case; Snapshot = $snapshot }
    } catch {
        if (Test-Path -LiteralPath $snapshot) {
            Get-ChildItem -LiteralPath $snapshot -File -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.IsReadOnly = $false }
            Remove-Item -LiteralPath $snapshot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $case.status = 'skipped'
        $case.reason = $_.Exception.Message
    }
}

$testFailed = $false
if (-not $SkipCompatibilityTests) {
    foreach ($entry in $copied) {
        $logPath = Join-Path $entry.Snapshot 'compatibility.log'
        $oldCorpus = $env:NEGATIVEZONE_INSTANCE_CORPUS_CASE
        $oldTemp = $env:TEMP
        $oldTmp = $env:TMP
        try {
            $env:NEGATIVEZONE_INSTANCE_CORPUS_CASE = $entry.Snapshot
            $env:TEMP = $testTemp
            $env:TMP = $testTemp
            Push-Location $clientDir
            try {
                $output = & go test .\cmd\nz\cmd -run '^TestCorpusCompatibility$' -count=1 -v 2>&1
                $exitCode = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            [IO.File]::WriteAllLines($logPath, @($output), [Text.UTF8Encoding]::new($false))
            if ($exitCode -eq 0) {
                $entry.Case.compatibility = 'passed'
            } else {
                $entry.Case.compatibility = 'failed'
                $entry.Case.reason = "compatibility test failed; see $logPath"
                $testFailed = $true
            }
        } finally {
            $env:NEGATIVEZONE_INSTANCE_CORPUS_CASE = $oldCorpus
            $env:TEMP = $oldTemp
            $env:TMP = $oldTmp
        }
    }
}

$report.completedAtUtc = [DateTime]::UtcNow.ToString('o')
$reportPath = Join-Path $runRoot 'report.json'
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

Write-Host "Corpus report: $reportPath"
foreach ($case in $report.candidates) {
    Write-Host ("[{0}] {1}: {2} {3}" -f $case.status, $case.displayName, $case.compatibility, $case.reason)
}
if ($testFailed) {
    exit 1
}
