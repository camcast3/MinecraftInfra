<#
.SYNOPSIS
    End-to-end test harness for the NegativeZone client install/update flow.

.DESCRIPTION
    Repeatable local verification of setup.ps1 + update.ps1 + backup.ps1 +
    the Prism PreLaunchCommand/PostExitCommand wrappers — without touching
    production (no Azure Blob, no real APPDATA, no real Prism, no network).

    What it does:
      1. Builds two fake "published" modpack zips (v1.0.0 and v1.1.0) from
         the real .ps1 sources in docs/assets/, mirroring the on-blob layout
         publish-prism-pack.ps1 produces.
      2. Spins up a tiny TcpListener-based HTTP server on a random loopback
         port (admin-free, no URL ACL) serving the zips + manifest +
         standalone update.ps1/backup.ps1 mirror files.
      3. Sets the three NEGATIVEZONE_* URL env vars + APPDATA to a sandbox.
      4. Runs setup.ps1 in subprocesses against the sandboxed APPDATA and
         asserts the expected on-disk state for each scenario:
           - Fresh install
           - Heal-broken-install (re-run after corruption)
           - Upgrade with snapshot+restore of player state
           - PreLaunchCommand wrapper: missing script   -> setup hint
           - PreLaunchCommand wrapper: parse error      -> setup hint
           - PreLaunchCommand wrapper: happy path       -> bubble exit code
           - PostExitCommand  wrapper: missing script   -> fail-open exit 0

    Each test gets a clean APPDATA so they're independent. Sandbox + HTTP
    server are torn down in `finally` so a Ctrl-C mid-run doesn't leak.

.PARAMETER Only
    Run only tests whose name matches this substring (case-insensitive).

.PARAMETER KeepSandbox
    Leave the sandbox directory in $env:TEMP for post-mortem inspection.

.EXAMPLE
    pwsh infra/azure/scripts/test-setup-e2e.ps1

.EXAMPLE
    pwsh infra/azure/scripts/test-setup-e2e.ps1 -Only PreLaunch -KeepSandbox
#>

[CmdletBinding()]
param(
    [string] $Only,
    [switch] $KeepSandbox
)

$ErrorActionPreference = 'Stop'
# Compress-Archive + Invoke-WebRequest both blast a progress bar to the host
# by default — turns the harness output into hard-to-read overwrites and on
# some terminals masks the actual test results. Suppressed here; explicit
# Write-Step messages give us all the progress we need.
$ProgressPreference = 'SilentlyContinue'

# ─── Locate repo + source scripts ───────────────────────────────────────────
$repoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..\..\..') | Select-Object -ExpandProperty Path
$docsAssets = Join-Path $repoRoot 'docs\assets'
$setupPs1          = Join-Path $docsAssets 'setup.ps1'
$updatePs1         = Join-Path $docsAssets 'update.ps1'
$backupPs1         = Join-Path $docsAssets 'backup.ps1'
$prelaunchCheckPs1 = Join-Path $docsAssets 'prelaunch-check.ps1'
$latestVersionTxt  = Join-Path $docsAssets 'latest-version.txt'

foreach ($f in @($setupPs1, $updatePs1, $backupPs1, $prelaunchCheckPs1, $latestVersionTxt)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing source: $f" }
}

# ─── Sandbox dirs ───────────────────────────────────────────────────────────
$sandbox      = Join-Path $env:TEMP ('nz-e2e-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss'))
$blobDir      = Join-Path $sandbox 'blob'
$logDir       = Join-Path $sandbox 'log'
New-Item -ItemType Directory -Path $blobDir, $logDir -Force | Out-Null

function Write-Section($t) { Write-Host ''; Write-Host ('=' * 60) -ForegroundColor DarkGray; Write-Host $t -ForegroundColor Cyan; Write-Host ('=' * 60) -ForegroundColor DarkGray }
function Write-Info($t)    { Write-Host "    $t" -ForegroundColor DarkGray }

# ─── Fixture builder: a published "modpack zip" ─────────────────────────────
# Mirrors publish-prism-pack.ps1's output:
#   <Instance>/instance.cfg
#   <Instance>/mmc-pack.json
#   <Instance>/.minecraft/mods/<some>.jar         (structural validation)
#   <Instance>/.negativezone/update.ps1           (with UTF-8 BOM)
#   <Instance>/.negativezone/backup.ps1           (with UTF-8 BOM)
#   <Instance>/.negativezone/preserve-list.json
function Build-FakeModpackZip {
    param(
        [Parameter(Mandatory)][string] $Version,
        [string] $InstanceName = 'Craft to Exile 2',
        [Parameter(Mandatory)][string] $OutDir,
        [string] $UpdatePs1Override,
        [string] $BackupPs1Override
    )
    $stage = Join-Path $env:TEMP ('nz-build-{0}' -f [guid]::NewGuid().ToString('N'))
    $instDir = Join-Path $stage $InstanceName
    $mcDir   = Join-Path $instDir '.minecraft'
    $modsDir = Join-Path $mcDir 'mods'
    $nzDir   = Join-Path $instDir '.negativezone'
    New-Item -ItemType Directory -Path $modsDir, $nzDir -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $modsDir "fabric-loader-v$Version.jar") `
                -Value "stub-mod-bytes-$Version" -Encoding ASCII

@"
[General]
ConfigVersion=1.2
iconKey=cte2
InstanceType=OneSix
name=NegativeZone CTE2 v$Version
OverrideCommands=true
"@ | Set-Content -LiteralPath (Join-Path $instDir 'instance.cfg') -Encoding UTF8

@"
{
  "components": [
    { "cachedName": "Minecraft", "cachedVersion": "1.20.1", "uid": "net.minecraft", "version": "1.20.1" }
  ],
  "formatVersion": 1
}
"@ | Set-Content -LiteralPath (Join-Path $instDir 'mmc-pack.json') -Encoding UTF8

    # Ship a real pack-author preserve manifest so the union code path in
    # setup.ps1 / update.ps1 (hardcoded ∪ preserve-list.json) is exercised
    # by the upgrade test. Format mirrors what publish-prism-pack.ps1 emits
    # from packwiz/.user-prefs.txt. Test entry is a synthetic mod-config
    # path so the test is independent of which mods C2E2 actually ships.
    @'
{"version":1,"preserve":["config/test-mod-prefs.json"]}
'@ | Set-Content -LiteralPath (Join-Path $nzDir 'preserve-list.json') -Encoding UTF8

    # Bundle .ps1 with UTF-8 BOM (mirrors Add-Ps1ZipEntry in publish-prism-pack.ps1).
    # Repo .ps1 files are BOM-less (lint-ps1.yml enforces this).
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $updBytes = if ($UpdatePs1Override) {
        $bom + [Text.UTF8Encoding]::new($false).GetBytes($UpdatePs1Override)
    } else {
        $bom + [IO.File]::ReadAllBytes($updatePs1)
    }
    $bakBytes = if ($BackupPs1Override) {
        $bom + [Text.UTF8Encoding]::new($false).GetBytes($BackupPs1Override)
    } else {
        $bom + [IO.File]::ReadAllBytes($backupPs1)
    }
    [IO.File]::WriteAllBytes((Join-Path $nzDir 'update.ps1'), $updBytes)
    [IO.File]::WriteAllBytes((Join-Path $nzDir 'backup.ps1'), $bakBytes)

    $zipName = "c2e2-v$Version.zip"
    $zipPath = Join-Path $OutDir $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    # Compress-Archive: -Path with trailing \* zips contents at root; without
    # it zips the dir itself. We want the dir IN the zip (setup.ps1 looks for
    # <InstanceName>/instance.cfg) so pass the dir directly.
    Compress-Archive -Path $instDir -DestinationPath $zipPath -CompressionLevel Fastest -Force

    Remove-Item $stage -Recurse -Force
    return $zipPath
}

function Write-Manifest {
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $InstanceName,
        [Parameter(Mandatory)][string] $BlobName,
        [Parameter(Mandatory)][string] $ZipPath,
        [Parameter(Mandatory)][string] $OutPath,
        [Parameter(Mandatory)][string] $BaseUrl,
        [switch] $AllowDowngrade
    )
    $sha = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLower()
    $size = (Get-Item -LiteralPath $ZipPath).Length
    $payload = [ordered]@{
        version   = $Version
        instance  = $InstanceName
        blob      = $BlobName
        url       = "$BaseUrl$BlobName"
        sha256    = $sha
        sizeBytes = $size
    }
    if ($AllowDowngrade) { $payload['allowDowngrade'] = $true }
    $json = ($payload | ConvertTo-Json -Compress)
    # PS 5.1's `Set-Content -Encoding UTF8` writes a UTF-8 BOM, which makes
    # Invoke-RestMethod on the receiving side bail out of JSON auto-parse
    # (it returns the raw string instead of an object). The real Azure Blob
    # responses don't have a BOM, so write BOM-less here to match.
    [IO.File]::WriteAllBytes($OutPath, [Text.UTF8Encoding]::new($false).GetBytes($json))
}

# ─── Tiny HTTP server (TcpListener-based, admin-free) ───────────────────────
Add-Type -Language CSharp @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class NzTestHttpServer {
    public static Thread Start(string serveDir, int port, CancellationToken ct) {
        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        var t = new Thread(() => {
            try {
                while (!ct.IsCancellationRequested) {
                    if (!listener.Pending()) { Thread.Sleep(20); continue; }
                    var client = listener.AcceptTcpClient();
                    Task.Run(() => Handle(client, serveDir));
                }
            } catch { }
            try { listener.Stop(); } catch { }
        });
        t.IsBackground = true;
        t.Start();
        return t;
    }
    static void Handle(TcpClient client, string serveDir) {
        try {
            using (var stream = client.GetStream())
            using (var reader = new StreamReader(stream, Encoding.ASCII, false, 8192, true)) {
                var requestLine = reader.ReadLine();
                if (requestLine == null) return;
                var parts = requestLine.Split(' ');
                if (parts.Length < 2) return;
                var pathQ = parts[1];
                var qIdx = pathQ.IndexOf('?');
                var rel = (qIdx >= 0 ? pathQ.Substring(0, qIdx) : pathQ).TrimStart('/');
                string line; while ((line = reader.ReadLine()) != null && line.Length > 0) { }
                var full = Path.Combine(serveDir, rel.Replace('/', Path.DirectorySeparatorChar));
                if (File.Exists(full)) {
                    var bytes = File.ReadAllBytes(full);
                    // Content-Type drives Invoke-RestMethod's auto-parse:
                    //   application/json  -> ConvertFrom-Json result (PSCustomObject)
                    //   text/plain        -> raw string
                    //   octet-stream      -> byte[] (breaks JSON deserialization
                    //                       and PS 5.1's `iex` on script text).
                    // Production blob storage serves json/ps1 with appropriate
                    // text/* types, so mirror that here.
                    var ext = Path.GetExtension(full).ToLowerInvariant();
                    string contentType;
                    switch (ext) {
                        case ".json": contentType = "application/json; charset=utf-8"; break;
                        case ".ps1":  contentType = "text/plain; charset=utf-8"; break;
                        case ".txt":  contentType = "text/plain; charset=utf-8"; break;
                        case ".zip":  contentType = "application/zip"; break;
                        default:      contentType = "application/octet-stream"; break;
                    }
                    var hdr = Encoding.ASCII.GetBytes(
                        "HTTP/1.1 200 OK\r\nContent-Length: " + bytes.Length +
                        "\r\nContent-Type: " + contentType +
                        "\r\nConnection: close\r\n\r\n");
                    stream.Write(hdr, 0, hdr.Length);
                    stream.Write(bytes, 0, bytes.Length);
                } else {
                    var hdr = Encoding.ASCII.GetBytes(
                        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    stream.Write(hdr, 0, hdr.Length);
                }
            }
        } catch { }
        finally { try { client.Close(); } catch { } }
    }
}
'@

function Start-NzHttpServer {
    param([Parameter(Mandatory)][string] $ServeDir)
    # Get a free port via ephemeral TcpListener probe
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()

    $cts = [System.Threading.CancellationTokenSource]::new()
    $thread = [NzTestHttpServer]::Start($ServeDir, $port, $cts.Token)
    Start-Sleep -Milliseconds 150

    return [pscustomobject]@{
        Port = $port
        BaseUrl = "http://127.0.0.1:$port/"
        Cts = $cts
        Thread = $thread
    }
}

function Stop-NzHttpServer {
    param($Server)
    if ($Server -and $Server.Cts) { $Server.Cts.Cancel() }
}

# ─── Invoke setup.ps1 in a clean subprocess against sandboxed APPDATA ───────
function Invoke-SetupPs1 {
    param(
        [Parameter(Mandatory)][string] $AppData,
        [Parameter(Mandatory)][string] $ManifestUrl,
        [Parameter(Mandatory)][string] $UpdateScriptUrl,
        [Parameter(Mandatory)][string] $BackupScriptUrl,
        [Parameter(Mandatory)][string] $PrelaunchCheckScriptUrl,
        [Parameter(Mandatory)][string] $LatestVersionUrl,
        [Parameter(Mandatory)][string] $SetupUrl,
        [string] $Label = 'setup'
    )
    New-Item -ItemType Directory -Path $AppData -Force | Out-Null

    # Mimic the production user flow as closely as possible:
    #   iwr -useb '<url>/setup.ps1' | iex
    # We can't pipe the same way in a script (would dot-source into a child
    # scope), so we use the documented equivalent: download as a string and
    # Invoke-Expression. Both go through Invoke-RestMethod's UTF-8 text
    # decoding, which is the path that makes setup.ps1's em-dashes work
    # without a BOM. PowerShell 5.1 `-File <script>` reads as Windows-1252
    # and corrupts those bytes.
    #
    # Every URL the script will hit is funneled through the local TcpListener
    # via the NEGATIVEZONE_*_URL overrides. NOTHING should reach the public
    # internet (production Azure blob, raw.githubusercontent.com) during a
    # harness run — confirms the e2e isolation contract.
    $bootstrap = @"
`$ProgressPreference = 'SilentlyContinue'
# When the harness is launched from pwsh (PS 7), PS 7's PSModulePath leaks
# into this powershell.exe child and prevents Microsoft.PowerShell.Utility
# (Get-FileHash, ConvertFrom-Json, etc.) from autoloading. Reset to Windows
# PowerShell 5.1's stock paths so module autoload behaves normally.
`$env:PSModulePath = @(
    "`$env:USERPROFILE\Documents\WindowsPowerShell\Modules",
    "`$env:ProgramFiles\WindowsPowerShell\Modules",
    "`$env:WINDIR\System32\WindowsPowerShell\v1.0\Modules"
) -join ';'
`$env:APPDATA = '$AppData'
# Setup writes archive zips to %LOCALAPPDATA%\NegativeZone\archives\.
# Without this override the test would pollute the developer's real
# AppData\Local.
`$env:LOCALAPPDATA = '$AppData\Local'
`$env:NEGATIVEZONE_NONINTERACTIVE = '1'
`$env:NEGATIVEZONE_SKIP_WINGET = '1'
`$env:NEGATIVEZONE_SKIP_BITS = '1'
`$env:NEGATIVEZONE_MANIFEST_URL = '$ManifestUrl'
`$env:NEGATIVEZONE_UPDATE_SCRIPT_URL = '$UpdateScriptUrl'
`$env:NEGATIVEZONE_BACKUP_SCRIPT_URL = '$BackupScriptUrl'
`$env:NEGATIVEZONE_PRELAUNCH_CHECK_SCRIPT_URL = '$PrelaunchCheckScriptUrl'
`$env:NEGATIVEZONE_LATEST_VERSION_URL = '$LatestVersionUrl'
`$setupSrc = Invoke-RestMethod -UseBasicParsing -Uri '$SetupUrl'
Invoke-Expression `$setupSrc
"@
    $bsFile = Join-Path $logDir ("bootstrap-{0}-{1}.ps1" -f $Label, [guid]::NewGuid().ToString('N').Substring(0,8))
    Set-Content -LiteralPath $bsFile -Value $bootstrap -Encoding UTF8

    $stdoutFile = Join-Path $logDir ("$Label.stdout.log")
    $stderrFile = Join-Path $logDir ("$Label.stderr.log")
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$bsFile) `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    $rc = $proc.ExitCode
    $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
    return [pscustomobject]@{
        ExitCode = $rc
        StdOut   = $stdout
        StdErr   = $stderr
        Output   = "$stdout`n$stderr"
        Log      = $stdoutFile
        ErrLog   = $stderrFile
    }
}

# Run the PreLaunchCommand from an installed instance.cfg as Prism would,
# substituting $INST_DIR. Returns ExitCode + Output.
function Invoke-PreLaunchCommand {
    param(
        [Parameter(Mandatory)][string] $InstanceDir,
        # Mirror Prism's CustomCommands env contract: INST_DIR is injected,
        # and the harness ALSO injects the test override env vars so the
        # on-disk prelaunch-check.ps1 hits the local TcpListener rather than
        # raw.githubusercontent.com. Caller can override for negative tests
        # (e.g. "what if the version URL is unreachable").
        [string] $LatestVersionUrl,
        [hashtable] $ExtraEnv
    )
    $cfgPath = Join-Path $InstanceDir 'instance.cfg'
    $cfg = Get-Content -LiteralPath $cfgPath
    $line = $cfg | Where-Object { $_ -match '^PreLaunchCommand=' } | Select-Object -First 1
    if (-not $line) { throw "No PreLaunchCommand in $cfgPath" }
    $raw = $line -replace '^PreLaunchCommand=', ''
    # Mirror Prism: Qt INI value -> un-escape -> QProcess::splitCommand.
    # Without this round-trip the harness would happily exec malformed cfg
    # bytes that Prism rejects in production (closing quote + space eaten,
    # \. dropped, \u eating the next char). The Qt-aware un-escape is the
    # canary that ensures setup.ps1 / publish-prism-pack.ps1 write values
    # in a form that survives Prism's launch-time re-read.
    $cmd = (ConvertFrom-QtIniValue -Raw $raw).Replace('$INST_DIR', $InstanceDir)
    # Simulate Prism's QProcess::splitCommand by handing the whole line to cmd /c.
    # Also export INST_DIR + NEGATIVEZONE_LATEST_VERSION_URL so child processes
    # use the local server.  ExtraEnv lets a test inject (or clear) more
    # variables, e.g. NEGATIVEZONE_SKIP_VERSION_CHECK=1.
    $envSetters = New-Object System.Collections.Generic.List[string]
    $envSetters.Add("set `"INST_DIR=$InstanceDir`"")
    if ($LatestVersionUrl) {
        $envSetters.Add("set `"NEGATIVEZONE_LATEST_VERSION_URL=$LatestVersionUrl`"")
    }
    if ($ExtraEnv) {
        foreach ($k in $ExtraEnv.Keys) {
            $envSetters.Add("set `"$k=$($ExtraEnv[$k])`"")
        }
    }
    $cmdFile = Join-Path $logDir ("pre-{0}.cmd" -f [guid]::NewGuid().ToString('N').Substring(0,8))
    $script = "@echo off`r`n" + (($envSetters -join "`r`n") + "`r`n") + "$cmd`r`nexit /b %ERRORLEVEL%"
    Set-Content -LiteralPath $cmdFile -Value $script -Encoding ASCII
    $out = & cmd.exe /c $cmdFile 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Invoke-PostExitCommand {
    param(
        [Parameter(Mandatory)][string] $InstanceDir,
        # Mirror of Invoke-PreLaunchCommand's ExtraEnv hook so tests can
        # inject e.g. NEGATIVEZONE_BACKUP_DAYS=0 to bypass the 3-day cadence
        # guard without monkey-patching backup.ps1 itself.
        [hashtable] $ExtraEnv
    )
    $cfg = Get-Content -LiteralPath (Join-Path $InstanceDir 'instance.cfg')
    $line = $cfg | Where-Object { $_ -match '^PostExitCommand=' } | Select-Object -First 1
    if (-not $line) { throw "No PostExitCommand in instance.cfg" }
    $raw = $line -replace '^PostExitCommand=', ''
    $cmd = (ConvertFrom-QtIniValue -Raw $raw).Replace('$INST_DIR', $InstanceDir)
    $envSetters = New-Object System.Collections.Generic.List[string]
    $envSetters.Add("set `"INST_DIR=$InstanceDir`"")
    if ($ExtraEnv) {
        foreach ($k in $ExtraEnv.Keys) {
            $envSetters.Add("set `"$k=$($ExtraEnv[$k])`"")
        }
    }
    $cmdFile = Join-Path $logDir ("post-{0}.cmd" -f [guid]::NewGuid().ToString('N').Substring(0,8))
    $script = "@echo off`r`n" + (($envSetters -join "`r`n") + "`r`n") + "$cmd`r`nexit /b %ERRORLEVEL%"
    Set-Content -LiteralPath $cmdFile -Value $script -Encoding ASCII
    $out = & cmd.exe /c $cmdFile 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

# Mirror of Qt's QSettings::iniUnescapedString — enough to round-trip values
# we write via Format-QtIniValue (\\ -> \, \" -> ", and standard letter
# escapes). Used by the launch-command helpers above so the harness fails
# exactly the way Prism does when a cfg value is mis-escaped.
function ConvertFrom-QtIniValue {
    param([Parameter(Mandatory)][string] $Raw)
    $s = $Raw
    # Strip a single pair of outer `"..."` if present.
    if ($s.Length -ge 2 -and $s[0] -eq '"' -and $s[$s.Length - 1] -eq '"') {
        $s = $s.Substring(1, $s.Length - 2)
    }
    $sb = New-Object Text.StringBuilder
    $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -eq '\' -and ($i + 1) -lt $s.Length) {
            $next = $s[$i + 1]
            switch ($next) {
                '\' { [void]$sb.Append('\'); $i += 2; continue }
                '"' { [void]$sb.Append('"'); $i += 2; continue }
                'n' { [void]$sb.Append("`n"); $i += 2; continue }
                'r' { [void]$sb.Append("`r"); $i += 2; continue }
                't' { [void]$sb.Append("`t"); $i += 2; continue }
                default {
                    # Qt drops the backslash and emits the next char alone for
                    # unknown escapes. That is the failure mode that broke the
                    # real-data run ('\.' -> '.', '\u' -> 'u' but then \uXXXX
                    # tries to consume 4 hex chars).
                    [void]$sb.Append($next); $i += 2; continue
                }
            }
        } else {
            [void]$sb.Append($c)
            $i++
        }
    }
    return $sb.ToString()
}

# ─── Test runner ────────────────────────────────────────────────────────────
$script:tests = New-Object System.Collections.Generic.List[object]
function Register-Test {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][scriptblock] $Body)
    $script:tests.Add([pscustomobject]@{ Name = $Name; Body = $Body })
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-PathExists {
    param([string] $Path, [string] $Message)
    Assert-True (Test-Path -LiteralPath $Path) ($Message + ": $Path")
}

function Assert-PathNotExists {
    param([string] $Path, [string] $Message)
    Assert-True (-not (Test-Path -LiteralPath $Path)) ($Message + ": $Path")
}

function Assert-FileContains {
    param([string] $Path, [string] $Pattern, [string] $Message)
    Assert-PathExists $Path "file must exist for content check"
    $content = Get-Content -LiteralPath $Path -Raw
    Assert-True ($content -match $Pattern) ($Message + " (pattern: $Pattern, in: $Path)")
}

# ─── Test cases ─────────────────────────────────────────────────────────────

Register-Test 'fresh-install' {
    param($ctx)
    $appData = Join-Path $sandbox 'appdata-fresh'
    $result = Invoke-SetupPs1 -AppData $appData `
        -ManifestUrl     $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl `
        -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl `
        -LatestVersionUrl        $ctx.LatestVersionUrl `
        -SetupUrl        $ctx.SetupUrl `
        -Label 'fresh'
    Assert-True ($result.ExitCode -eq 0) "setup.ps1 must exit 0 (got $($result.ExitCode); log: $($result.Log))"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    Assert-PathExists $inst 'instance directory created'
    Assert-PathExists (Join-Path $inst 'instance.cfg') 'instance.cfg'
    Assert-PathExists (Join-Path $inst '.minecraft\mods\fabric-loader-v1.0.0.jar') 'mod jar present'
    Assert-PathExists (Join-Path $inst '.negativezone\update.ps1') 'update.ps1 bundled'
    Assert-PathExists (Join-Path $inst '.negativezone\backup.ps1') 'backup.ps1 bundled'
    Assert-PathExists (Join-Path $inst '.negativezone\prelaunch-check.ps1') 'prelaunch-check.ps1 bundled'
    Assert-PathExists (Join-Path $inst '.negativezone-version') 'version marker'
    Assert-FileContains (Join-Path $inst '.negativezone-version') '^1\.0\.0' 'version marker matches manifest'
    Assert-FileContains (Join-Path $inst 'instance.cfg') 'OverrideCommands=true' 'OverrideCommands set'
    Assert-FileContains (Join-Path $inst 'instance.cfg') 'PreLaunchCommand=.*scriptblock.*prelaunch-check\.ps1' 'PreLaunchCommand wired to scriptblock wrapper'
    Assert-FileContains (Join-Path $inst 'instance.cfg') 'PostExitCommand=.*scriptblock.*backup\.ps1' 'PostExitCommand wired'
    Assert-FileContains (Join-Path $inst 'instance.cfg') 're-run the setup one-liner' 'PreLaunch wrapper carries setup hint'
    Assert-PathNotExists "$inst.bak" 'no .bak for first install'
}

Register-Test 'heal-broken-install' {
    param($ctx)
    $appData = Join-Path $sandbox 'appdata-heal'
    # Step 1: fresh install
    $r1 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'heal-1'
    Assert-True ($r1.ExitCode -eq 0) "first install must succeed (rc=$($r1.ExitCode))"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    $updateFile = Join-Path $inst '.negativezone\update.ps1'

    # Step 2: corrupt update.ps1 with a parse error (the original em-dash bug class)
    Set-Content -LiteralPath $updateFile -Value 'function { broken syntax }' -Encoding UTF8

    # Step 3: re-run setup.ps1; same manifest version, should still re-fetch hook scripts
    $r2 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'heal-2'
    Assert-True ($r2.ExitCode -eq 0) "re-run must succeed (rc=$($r2.ExitCode))"

    # Verify update.ps1 was re-downloaded (no longer the broken stub)
    $healed = Get-Content -LiteralPath $updateFile -Raw
    Assert-True ($healed -notmatch 'function \{ broken syntax \}') 'update.ps1 was re-fetched (broken stub gone)'
    Assert-True ($healed -match 'NegativeZone client auto-update') 'update.ps1 has real content'
}

Register-Test 'upgrade-with-snapshot-restore' {
    param($ctx)
    $appData = Join-Path $sandbox 'appdata-upgrade'
    # Step 1: install v1.0.0
    $r1 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'upg-1'
    Assert-True ($r1.ExitCode -eq 0) "v1.0.0 install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'

    # Step 2: simulate player state — drop sentinel files in each preserved location
    $mcDir = Join-Path $inst '.minecraft'
    New-Item -ItemType Directory -Path "$mcDir\saves\my-world\region" -Force | Out-Null
    Set-Content -LiteralPath "$mcDir\saves\my-world\region\r.0.0.mca" -Value 'player-world-bytes'
    Set-Content -LiteralPath "$mcDir\options.txt"    -Value 'mouseSensitivity:0.4'
    Set-Content -LiteralPath "$mcDir\optionsof.txt"  -Value 'renderDistance:16'
    Set-Content -LiteralPath "$mcDir\usercache.json" -Value '[{"name":"player1"}]'
    Set-Content -LiteralPath "$mcDir\hotbar.nbt"     -Value 'hotbar-sentinel-bytes'
    New-Item -ItemType Directory -Path "$mcDir\XaeroWorldMap\sp" -Force | Out-Null
    Set-Content -LiteralPath "$mcDir\XaeroWorldMap\sp\waypoint.json" -Value '{"x":100}'
    New-Item -ItemType Directory -Path "$mcDir\journeymap\data\sp" -Force | Out-Null
    Set-Content -LiteralPath "$mcDir\journeymap\data\sp\waypoints.json" -Value '{"jm-waypoint":"home"}'
    New-Item -ItemType Directory -Path "$mcDir\shaderpacks" -Force | Out-Null
    Set-Content -LiteralPath "$mcDir\shaderpacks\Sildurs.zip" -Value 'shaderdata'
    # Pack-author preserve-list.json entry — proves the hardcoded ∪ manifest
    # union path works (this file isn't on setup.ps1's hardcoded $preserveList,
    # so it can only be restored via the preserve-list.json union code path).
    New-Item -ItemType Directory -Path "$mcDir\config" -Force | Out-Null
    Set-Content -LiteralPath "$mcDir\config\test-mod-prefs.json" -Value '{"emiEnabled":false}'

    # Step 3: publish v1.1.0
    $ctx.PublishVersion.Invoke('1.1.0')

    # Step 4: re-run setup.ps1 with new manifest
    $r2 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'upg-2'
    Assert-True ($r2.ExitCode -eq 0) "v1.1.0 upgrade must succeed (rc=$($r2.ExitCode))"

    # Step 5: verify
    $bak = "$inst.bak"
    Assert-PathExists $bak '.bak created from old instance'
    Assert-PathExists (Join-Path $bak '.minecraft\saves\my-world\region\r.0.0.mca') '.bak preserves saves'
    Assert-PathExists (Join-Path $bak '.minecraft\options.txt') '.bak preserves options.txt'
    Assert-PathExists (Join-Path $inst '.minecraft\mods\fabric-loader-v1.1.0.jar') 'v1.1.0 mod installed'
    Assert-PathNotExists (Join-Path $inst '.minecraft\mods\fabric-loader-v1.0.0.jar') 'v1.0.0 mod removed'
    Assert-FileContains (Join-Path $inst '.negativezone-version') '^1\.1\.0' 'version marker bumped'

    # Permanent archive zip — the "never lose data" safety net. Lives outside
    # the Prism instances dir so future setup runs cannot touch it.
    $archiveDir = Join-Path $appData 'Local\NegativeZone\archives'
    Assert-PathExists $archiveDir 'permanent archive directory created'
    $archives = @(Get-ChildItem -LiteralPath $archiveDir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    Assert-True ($archives.Count -ge 1) "at least one archive zip created (found $($archives.Count))"
    $archive = $archives | Select-Object -First 1
    Assert-True ($archive.Length -gt 1024) "archive zip is non-empty (got $($archive.Length) bytes — should contain mods + saves + options)"
    Assert-True ($archive.Name -match '^Craft to Exile 2_v1\.0\.0_\d{8}-\d{6}\.zip$') "archive zip named with prior version + timestamp (got '$($archive.Name)')"
    # And verify the zip actually contains the player state we'd want to recover
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($archive.FullName)
    try {
        $entryNames = @($zipArchive.Entries | ForEach-Object { $_.FullName })
        Assert-True (($entryNames | Where-Object { $_ -match '\.minecraft[\\/]options\.txt$' }).Count -gt 0) 'archive zip contains options.txt'
        Assert-True (($entryNames | Where-Object { $_ -match '\.minecraft[\\/]hotbar\.nbt$' }).Count -gt 0) 'archive zip contains hotbar.nbt'
        Assert-True (($entryNames | Where-Object { $_ -match '\.minecraft[\\/]saves[\\/]' }).Count -gt 0) 'archive zip contains saves/'
    } finally {
        $zipArchive.Dispose()
    }

    # Side-by-side "(old)" instance — must be a Prism-visible launchable
    # instance with the prelaunch update hook DISABLED so the player can
    # roll back from the UI without being blocked.
    $oldInst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2 (old)'
    Assert-PathExists $oldInst 'side-by-side (old) instance created'
    Assert-PathExists (Join-Path $oldInst '.minecraft\options.txt') 'side-by-side preserves options.txt'
    Assert-PathExists (Join-Path $oldInst 'instance.cfg') 'side-by-side has instance.cfg'
    Assert-FileContains (Join-Path $oldInst 'instance.cfg') '(?m)^OverrideCommands=false' 'side-by-side has prelaunch hooks disabled (cannot be blocked by version check)'
    Assert-FileContains (Join-Path $oldInst 'instance.cfg') '(?m)^name=Craft to Exile 2 v1\.0\.0 \(old\)' 'side-by-side display name marked as old'
    # And the Prism group config places it under Backup
    Assert-FileContains (Join-Path $appData 'PrismLauncher\instances\instgroups.json') 'Craft to Exile 2 \(old\)' 'side-by-side instance is in Prism instgroups.json'

    # Restored player state — these are the critical checks
    Assert-PathExists (Join-Path $inst '.minecraft\saves\my-world\region\r.0.0.mca') 'saves RESTORED into v1.1.0'
    Assert-FileContains (Join-Path $inst '.minecraft\options.txt') 'mouseSensitivity:0\.4' 'options.txt RESTORED with content'
    Assert-FileContains (Join-Path $inst '.minecraft\optionsof.txt') 'renderDistance:16' 'optionsof.txt RESTORED'
    Assert-FileContains (Join-Path $inst '.minecraft\usercache.json') 'player1' 'usercache RESTORED'
    Assert-FileContains (Join-Path $inst '.minecraft\hotbar.nbt') 'hotbar-sentinel-bytes' 'hotbar.nbt RESTORED'
    Assert-PathExists (Join-Path $inst '.minecraft\XaeroWorldMap\sp\waypoint.json') 'XaeroWorldMap RESTORED'
    Assert-PathExists (Join-Path $inst '.minecraft\journeymap\data\sp\waypoints.json') 'journeymap RESTORED'
    Assert-PathExists (Join-Path $inst '.minecraft\shaderpacks\Sildurs.zip') 'shaderpacks RESTORED'
    # Pack-author preserve-list.json union — proves mod configs (e.g. EMI
    # enable/disable state) survive setup-driven upgrades, not just
    # update.ps1-driven ones. Was silently broken before this fix.
    Assert-FileContains (Join-Path $inst '.minecraft\config\test-mod-prefs.json') 'emiEnabled' 'pack-author preserve-list.json entry RESTORED (union with hardcoded list)'

    # Reset for subsequent tests
    $ctx.PublishVersion.Invoke('1.0.0')
}

Register-Test 'prelaunch-missing-script' {
    param($ctx)
    # PreLaunch now invokes prelaunch-check.ps1 (not update.ps1) — that's
    # the load-bearing script for blocking stale launches. If a user deletes
    # or corrupts it, Prism must hard-fail with the "re-run setup" hint
    # rather than silently allowing a stale launch.
    $appData = Join-Path $sandbox 'appdata-pre-missing'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'pre-miss-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    Remove-Item (Join-Path $inst '.negativezone\prelaunch-check.ps1') -Force

    $pre = Invoke-PreLaunchCommand -InstanceDir $inst -LatestVersionUrl $ctx.LatestVersionUrl
    Assert-True ($pre.ExitCode -eq 1) "PreLaunch must exit 1 (got $($pre.ExitCode))"
    $joined = ($pre.Output -join "`n")
    Assert-True ($joined -match 're-run the setup one-liner') "Must contain setup hint. Output: $joined"
    Assert-True ($joined -match 'PreLaunch hook failed') "Must contain failure header"
}

Register-Test 'prelaunch-parse-error' {
    param($ctx)
    # Corrupted prelaunch-check.ps1 must also be caught by the try/catch
    # wrapper in instance.cfg's PreLaunchCommand and surface the same
    # "client is broken, re-run setup" UX as a missing script.
    $appData = Join-Path $sandbox 'appdata-pre-parse'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'pre-parse-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    Set-Content -LiteralPath (Join-Path $inst '.negativezone\prelaunch-check.ps1') -Value 'function { unbalanced' -Encoding UTF8

    $pre = Invoke-PreLaunchCommand -InstanceDir $inst -LatestVersionUrl $ctx.LatestVersionUrl
    Assert-True ($pre.ExitCode -eq 1) "parse-error must exit 1"
    $joined = ($pre.Output -join "`n")
    Assert-True ($joined -match 're-run the setup one-liner') "Must contain setup hint"
}

Register-Test 'prelaunch-happy-path' {
    param($ctx)
    # When installed == latest, prelaunch-check.ps1 exits 0 silently — no
    # banner, no "update available" prompt, no perceptible delay. This is
    # the launch path that runs EVERY time a player clicks Play, so any
    # output here is user-visible noise.
    $appData = Join-Path $sandbox 'appdata-pre-ok'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'pre-ok-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    # latest-version.txt is staged with the just-installed version (1.0.0)
    # already, so prelaunch-check should see installed == latest.

    $pre = Invoke-PreLaunchCommand -InstanceDir $inst -LatestVersionUrl $ctx.LatestVersionUrl
    Assert-True ($pre.ExitCode -eq 0) "happy path must exit 0 (got $($pre.ExitCode))"
    $joined = ($pre.Output -join "`n")
    Assert-True ($joined -notmatch 're-run the setup one-liner') "Must NOT contain setup hint on success"
    Assert-True ($joined -notmatch 'MODPACK VERSION MISMATCH') "Must NOT show mismatch banner when current"
}

Register-Test 'prelaunch-blocks-when-stale' {
    param($ctx)
    # New behaviour: when latest-version.txt is ahead of installed,
    # prelaunch-check MUST exit 1 (hard block), show the MODPACK VERSION
    # MISMATCH banner, and surface the irm update.ps1 one-liner. This is
    # the whole point of the new architecture — without this guard players
    # could join a multiplayer server with a stale modpack and the FML
    # handshake would boot them anyway. Better to block with instructions.
    $appData = Join-Path $sandbox 'appdata-pre-stale'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'pre-stale-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed (rc=$($r.ExitCode))"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'

    & $ctx.BumpLatestVersion 1.1.0
    try {
        $pre = Invoke-PreLaunchCommand -InstanceDir $inst -LatestVersionUrl $ctx.LatestVersionUrl
        Assert-True ($pre.ExitCode -eq 1) "stale launch must exit 1 (got $($pre.ExitCode))"
        $joined = ($pre.Output -join "`n")
        Assert-True ($joined -match 'MODPACK VERSION MISMATCH') "Must show MODPACK VERSION MISMATCH banner. Output: $joined"
        Assert-True ($joined -match 'behind') "Banner must call out 'behind' direction when installed < latest. Output: $joined"
        Assert-True ($joined -match 'iex')               "Must show iex one-liner so player can run update. Output: $joined"
        Assert-True ($joined -match 'update\.ps1')       "Must reference update.ps1. Output: $joined"
    } finally {
        & $ctx.BumpLatestVersion 1.0.0  # reset for subsequent tests
    }
}

Register-Test 'prelaunch-blocks-when-installed-ahead' {
    param($ctx)
    # Strict-equality contract (forced while lifecycle scripts are still
    # being shaken out): a player whose installed version is AHEAD of the
    # server-pinned pointer must also be blocked. Real-world trigger:
    # admin republished an older modpack under allowDowngrade:true and the
    # player hasn't run update.ps1 yet. Allowing them through would risk
    # the same FML handshake mismatch as the "behind" case.
    $appData = Join-Path $sandbox 'appdata-pre-ahead'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'pre-ahead-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed (rc=$($r.ExitCode))"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'

    # Install was v1.0.0; roll the pointer DOWN to v0.9.0 so installed > latest.
    & $ctx.BumpLatestVersion 0.9.0
    try {
        $pre = Invoke-PreLaunchCommand -InstanceDir $inst -LatestVersionUrl $ctx.LatestVersionUrl
        Assert-True ($pre.ExitCode -eq 1) "installed-ahead launch must exit 1 (got $($pre.ExitCode))"
        $joined = ($pre.Output -join "`n")
        Assert-True ($joined -match 'MODPACK VERSION MISMATCH') "Must show MODPACK VERSION MISMATCH banner. Output: $joined"
        Assert-True ($joined -match 'ahead') "Banner must call out 'ahead' direction when installed > latest. Output: $joined"
        Assert-True ($joined -match 'allowDowngrade') "Must mention allowDowngrade so player understands rollback path. Output: $joined"
    } finally {
        & $ctx.BumpLatestVersion 1.0.0  # reset for subsequent tests
    }
}

Register-Test 'prelaunch-bypass-env-allows-stale' {
    param($ctx)
    # Offline-play / dev escape hatch: NEGATIVEZONE_SKIP_VERSION_CHECK=1
    # bypasses the stale guard entirely. Useful for LAN parties where the
    # GitHub pointer is unreachable but local servers are running, and for
    # us when debugging without re-publishing.
    $appData = Join-Path $sandbox 'appdata-pre-bypass'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'pre-bypass-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    & $ctx.BumpLatestVersion 1.1.0
    try {
        $pre = Invoke-PreLaunchCommand -InstanceDir $inst `
            -LatestVersionUrl $ctx.LatestVersionUrl `
            -ExtraEnv @{ NEGATIVEZONE_SKIP_VERSION_CHECK = '1' }
        Assert-True ($pre.ExitCode -eq 0) "bypass env must let launch proceed (got $($pre.ExitCode))"
        $joined = ($pre.Output -join "`n")
        Assert-True ($joined -notmatch 'MODPACK VERSION MISMATCH') "Bypass must suppress mismatch banner. Output: $joined"
    } finally {
        & $ctx.BumpLatestVersion 1.0.0
    }
}

Register-Test 'prelaunch-fails-open-when-pointer-unreachable' {
    param($ctx)
    # If raw.githubusercontent.com is down or the player is offline,
    # prelaunch-check MUST NOT block the launch. Offline single-player
    # should always work even when the version pointer can't be fetched.
    # Fail-open is critical here — fail-closed would mean any GitHub outage
    # is a complete-platform outage for our players.
    $appData = Join-Path $sandbox 'appdata-pre-offline'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'pre-offline-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    # Point at a 404 path on the (running) test server — simulates DNS works
    # but the file is missing / 5xx / network blip.
    $deadUrl = "$($ctx.BlobBaseUrl)does-not-exist-$([guid]::NewGuid().ToString('N')).txt"
    $pre = Invoke-PreLaunchCommand -InstanceDir $inst -LatestVersionUrl $deadUrl
    Assert-True ($pre.ExitCode -eq 0) "unreachable pointer must fail OPEN (got $($pre.ExitCode))"
    $joined = ($pre.Output -join "`n")
    Assert-True ($joined -notmatch 'MODPACK VERSION MISMATCH') "Must NOT block when version check fails. Output: $joined"
}

Register-Test 'postexit-fail-open' {
    param($ctx)
    $appData = Join-Path $sandbox 'appdata-post-miss'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'post-miss-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    Remove-Item (Join-Path $inst '.negativezone\backup.ps1') -Force

    $post = Invoke-PostExitCommand -InstanceDir $inst
    Assert-True ($post.ExitCode -eq 0) "PostExit must fail OPEN (exit 0; got $($post.ExitCode))"
    $joined = ($post.Output -join "`n")
    Assert-True ($joined -match 're-run the setup one-liner') "Must still show setup hint in output"
}

Register-Test 'postexit-snapshot-captures-directories' {
    param($ctx)
    # Regression test for the v0.4.2 robocopy-exit-16 bug.
    #
    # backup.ps1 used `Start-Process robocopy -ArgumentList @($src,$dst,...)`
    # which in Windows PowerShell 5.1 (what Prism PostExit shells out to)
    # does NOT quote array elements containing spaces. The instance dir
    # 'Craft to Exile 2' has TWO spaces, so robocopy received:
    #   arg1 = 'C:\...\instances\Craft'
    #   arg2 = 'to'
    #   arg3 = 'Exile'
    #   arg4 = '2\.minecraft\shaderpacks'   <- "Invalid Parameter #4"
    # …and silently exited 16 for every directory in $DirectoryItems while
    # the snapshot kept being marked "successful" because the file items
    # (options.txt, servers.dat) still copied via Copy-Item. Net effect: a
    # year of Xaero map cache + shaderpacks could be lost the next time the
    # modpack updated, with no visible warning to the player.
    #
    # This test seeds real directory content under .minecraft/<scope>/ and
    # asserts the resulting snapshot dir contains those bytes — which only
    # works if robocopy actually copied them.
    $appData = Join-Path $sandbox 'appdata-post-snap'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl -SetupUrl $ctx.SetupUrl -Label 'post-snap-install'
    Assert-True ($r.ExitCode -eq 0) "install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    # Instance path MUST contain a space for this test to be load-bearing —
    # the bug only fires when the source path has spaces.
    Assert-True ($inst -match ' ') "instance path must contain a space to exercise the bug (got: $inst)"
    $dotMc = Join-Path $inst '.minecraft'

    # Seed a representative subset of $DirectoryItems with real bytes.
    # Mixing dirs (shaderpacks, resourcepacks), a nested dir (config/jei),
    # and an empty dir (screenshots) covers the failure modes we saw live.
    $fixtures = @{
        'shaderpacks\my-shader.zip.txt'    = 'fake shader pack content'
        'resourcepacks\my-pack.zip.txt'    = 'fake resource pack content'
        'config\jei\bookmarks.ini'         = 'recipe-1`r`nrecipe-2'
        'XaeroWaypoints\dim%2A0.txt'       = 'waypoint data'
    }
    foreach ($rel in $fixtures.Keys) {
        $p = Join-Path $dotMc $rel
        $parent = [IO.Path]::GetDirectoryName($p)
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Set-Content -LiteralPath $p -Value $fixtures[$rel] -Encoding UTF8
    }
    # Empty dir — robocopy on empty src + /MIR is non-fatal (exit 0).
    New-Item -ItemType Directory -Path (Join-Path $dotMc 'screenshots') -Force | Out-Null

    # NEGATIVEZONE_BACKUP_DAYS=0 forces backup.ps1 past the cadence guard.
    $post = Invoke-PostExitCommand -InstanceDir $inst -ExtraEnv @{ NEGATIVEZONE_BACKUP_DAYS = '0' }
    Assert-True ($post.ExitCode -eq 0) "PostExit must exit 0 (got $($post.ExitCode)). Output: $($post.Output -join "`n")"

    $bakRoot = Join-Path $inst '.negativezone\backups'
    Assert-True (Test-Path -LiteralPath $bakRoot) "backups root must exist"
    $snap = Get-ChildItem -LiteralPath $bakRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    Assert-True ($null -ne $snap) "at least one snapshot dir must exist after PostExit"

    # Every seeded directory file must be present in the snapshot. This is
    # the assertion the exit-16 regression would fail on — under the bug,
    # the snapshot would contain options.txt / servers.dat only.
    foreach ($rel in $fixtures.Keys) {
        $snapPath = Join-Path $snap.FullName $rel
        Assert-PathExists $snapPath "snapshot missing '$rel' — robocopy likely failed (exit 16)"
        $src = Join-Path $dotMc $rel
        $srcBytes = [IO.File]::ReadAllBytes($src)
        $dstBytes = [IO.File]::ReadAllBytes($snapPath)
        Assert-True ($srcBytes.Length -eq $dstBytes.Length) "size mismatch on '$rel' ($($srcBytes.Length) -> $($dstBytes.Length))"
    }

    # backup.log MUST NOT contain any "robocopy ... failed (exit 16)" lines.
    # Even if the snapshot ends up populated some other way, the presence
    # of that WARN is the canary symptom we're guarding against.
    $logPath = Join-Path $inst '.negativezone\backup.log'
    if (Test-Path -LiteralPath $logPath) {
        $logText = Get-Content -LiteralPath $logPath -Raw
        Assert-True ($logText -notmatch 'robocopy .* failed \(exit 16\)') "backup.log contains exit-16 WARN — the Start-Process quoting bug regressed."
    }
}

Register-Test 'cfg-qt-ini-escape-roundtrip' {
    param($ctx)
    # Catches the v0.4.2 regression where setup.ps1 wrote unescaped
    # `"powershell.exe" -NoProfile ... $INST_DIR\.negativezone\update.ps1`
    # straight into instance.cfg. Prism's Qt INI reader collapsed the
    # value on first launch (closing quote + space eaten, `\.` dropped,
    # `\u` consumed the `u` from `update`), breaking PreLaunch with
    # "process failed to start". This test asserts that the on-disk
    # PreLaunchCommand round-trips through ConvertFrom-QtIniValue back to
    # the exact byte sequence we wanted Prism to receive.
    $appData = Join-Path $sandbox 'appdata-qt-escape'
    $r = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'qt-escape'
    Assert-True ($r.ExitCode -eq 0) "install must succeed (rc=$($r.ExitCode))"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    $line = Get-Content -LiteralPath (Join-Path $inst 'instance.cfg') |
        Where-Object { $_ -match '^PreLaunchCommand=' } | Select-Object -First 1
    Assert-True ($null -ne $line) "PreLaunchCommand line present"

    # On-disk form MUST be wrapped + escaped, not the raw `"powershell.exe" ...`
    # form that was broken in production. The wrap is the load-bearing bit:
    # without outer `"..."` Qt parses adjacent quoted/unquoted segments and
    # concatenates them with the space stripped.
    $raw = $line -replace '^PreLaunchCommand=', ''
    Assert-True ($raw.StartsWith('"') -and $raw.EndsWith('"')) `
        "PreLaunchCommand value must be wrapped in outer quotes (got: $raw)"
    Assert-True ($raw -match '\\\\\.negativezone\\\\prelaunch-check\.ps1') `
        ('Path backslashes must be escaped as \\ (got: ' + $raw + ')')
    Assert-True ($raw -match '\\"powershell\.exe\\"') `
        ('Inner quotes must be escaped as backslash-quote (got: ' + $raw + ')')

    # And the un-escape round-trips back to a string that LOOKS like a
    # valid PS command line — exactly what Prism feeds QProcess::splitCommand.
    $unwrapped = ConvertFrom-QtIniValue -Raw $raw
    Assert-True ($unwrapped -match '"powershell\.exe" -NoProfile') `
        "Un-escaped value must have intact quoted exe path + space (got: $unwrapped)"
    Assert-True ($unwrapped -match '\$INST_DIR\\\.negativezone\\prelaunch-check\.ps1') `
        ('Un-escaped value must preserve $INST_DIR\.negativezone\prelaunch-check.ps1 (got: ' + $unwrapped + ')')
}

Register-Test 'instance-name-bumped-on-upgrade' {
    param($ctx)
    # The original v0.4.2 real-data run shipped a zip whose instance.cfg
    # still had `name=Craft to Exile 2 v0.4.1` baked in, and setup.ps1
    # never rewrote it after extract — both the live install and the .bak
    # showed up as `v0.4.1` in Prism's grid. Setup.ps1 must overwrite the
    # name with the manifest version regardless of what the zip contained.
    $appData = Join-Path $sandbox 'appdata-name-bump'
    $r1 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'name-1'
    Assert-True ($r1.ExitCode -eq 0) "v1.0.0 install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    Assert-FileContains (Join-Path $inst 'instance.cfg') '(?m)^name=Craft to Exile 2 v1\.0\.0' `
        'name= must include the current manifest version after install'

    # Upgrade to v1.1.0 and verify name= bumps on the live install while
    # the .bak still has the old name=.
    $ctx.PublishVersion.Invoke('1.1.0')
    $r2 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'name-2'
    Assert-True ($r2.ExitCode -eq 0) "v1.1.0 upgrade must succeed"
    Assert-FileContains (Join-Path $inst 'instance.cfg') '(?m)^name=Craft to Exile 2 v1\.1\.0' `
        'live install name= bumped to v1.1.0'
    Assert-FileContains (Join-Path "$inst.bak" 'instance.cfg') '(?m)^name=Craft to Exile 2 v1\.0\.0' `
        '.bak name= preserved at v1.0.0'

    $ctx.PublishVersion.Invoke('1.0.0')  # reset for subsequent tests
}

Register-Test 'instgroups-latest-and-backup' {
    param($ctx)
    # Before this fix Prism showed both the live install and the .bak in
    # the default "Ungrouped" bucket with identical display names — players
    # had no quick way to tell which one was current. Setup.ps1 now writes
    # instgroups.json so the live instance lands in "Latest" and the .bak
    # (if any) lands in "Backup". Also asserts that on a FRESH install
    # (no .bak yet) we only create the Latest group.
    $appData = Join-Path $sandbox 'appdata-groups'
    $r1 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'grp-1'
    Assert-True ($r1.ExitCode -eq 0) "fresh install must succeed"

    $groupsFile = Join-Path $appData 'PrismLauncher\instances\instgroups.json'
    Assert-PathExists $groupsFile 'instgroups.json created'
    $groups = Get-Content -LiteralPath $groupsFile -Raw | ConvertFrom-Json
    Assert-True ($groups.groups.Latest -ne $null) 'Latest group present after fresh install'
    Assert-True (@($groups.groups.Latest.instances) -contains 'Craft to Exile 2') `
        'Latest group contains live instance'
    Assert-True ($groups.groups.Backup -eq $null) 'No Backup group when no .bak exists'

    # Upgrade -> .bak should appear AND get filed under Backup.
    $ctx.PublishVersion.Invoke('1.1.0')
    $r2 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'grp-2'
    Assert-True ($r2.ExitCode -eq 0) "upgrade must succeed"

    $groups2 = Get-Content -LiteralPath $groupsFile -Raw | ConvertFrom-Json
    Assert-True (@($groups2.groups.Latest.instances) -contains 'Craft to Exile 2') `
        'Latest still contains live instance after upgrade'
    Assert-True ($groups2.groups.Backup -ne $null) 'Backup group exists after upgrade'
    Assert-True (@($groups2.groups.Backup.instances) -contains 'Craft to Exile 2.bak') `
        'Backup group contains .bak'
    Assert-True ((@($groups2.groups.Latest.instances) | Where-Object { $_ -eq 'Craft to Exile 2.bak' }).Count -eq 0) `
        '.bak NOT also stuck in Latest group'

    # Idempotency: a player-created group survives reasserts.
    $custom = @{
        formatVersion = '1'
        groups = @{
            Latest = @{ hidden = $false; instances = @('Craft to Exile 2') }
            Backup = @{ hidden = $false; instances = @('Craft to Exile 2.bak') }
            MyPersonalGroup = @{ hidden = $false; instances = @('Vanilla 1.20') }
        }
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllBytes($groupsFile, [Text.UTF8Encoding]::new($false).GetBytes($custom))
    $r3 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'grp-3'
    Assert-True ($r3.ExitCode -eq 0) "third run (same version) must succeed"

    $groups3 = Get-Content -LiteralPath $groupsFile -Raw | ConvertFrom-Json
    Assert-True ($groups3.groups.MyPersonalGroup -ne $null) `
        'User-created group survived setup.ps1 group reassert'
    Assert-True (@($groups3.groups.MyPersonalGroup.instances) -contains 'Vanilla 1.20') `
        'User group contents preserved'

    $ctx.PublishVersion.Invoke('1.0.0')  # reset
}

Register-Test 'no-downgrade-by-default' {
    param($ctx)
    # If the published manifest version drops below what's installed (admin
    # typo, stale local test manifest, mis-aimed -ManifestUrl override),
    # setup.ps1 and update.ps1 must BOTH refuse to silently roll the player
    # back. The .bak strategy only protects one level of history, so a
    # spurious downgrade-then-update sequence would permanently erase the
    # actual previous version. Allow only when the manifest opts in with
    # allowDowngrade:true, which is how admins ship intentional emergency
    # rollbacks.
    $appData = Join-Path $sandbox 'appdata-no-downgrade'

    # Step 1: install v1.1.0 fresh
    $ctx.PublishVersion.Invoke('1.1.0')
    $r1 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'no-down-1'
    Assert-True ($r1.ExitCode -eq 0) "v1.1.0 install must succeed"

    $inst = Join-Path $appData 'PrismLauncher\instances\Craft to Exile 2'
    Assert-FileContains (Join-Path $inst '.negativezone-version') '^1\.1\.0' 'starts on v1.1.0'

    # Step 2: roll the published manifest BACKWARDS to v1.0.0 with NO opt-in.
    # Re-run setup.ps1 — must stay on v1.1.0.
    $ctx.PublishVersion.Invoke('1.0.0')
    $r2 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'no-down-2'
    Assert-True ($r2.ExitCode -eq 0) "setup.ps1 must exit 0 even when refusing downgrade"
    Assert-FileContains (Join-Path $inst '.negativezone-version') '^1\.1\.0' `
        'setup.ps1 must NOT downgrade from v1.1.0 to v1.0.0 without opt-in'

    # And update.ps1 must skip too — invoke it DIRECTLY (not via PreLaunch
    # any more — PreLaunch runs prelaunch-check.ps1 now, which has no
    # downgrade opinion). update.ps1 is what the user runs via the
    # `irm | iex` one-liner, so its downgrade guard remains critical: if
    # an admin accidentally rolls latest-version.txt back, the user who
    # runs update should be told no.
    $updateBootstrap = @"
`$env:PSModulePath = @(
    "`$env:USERPROFILE\Documents\WindowsPowerShell\Modules",
    "`$env:ProgramFiles\WindowsPowerShell\Modules",
    "`$env:WINDIR\System32\WindowsPowerShell\v1.0\Modules"
) -join ';'
`$env:INST_DIR = '$inst'
`$env:NEGATIVEZONE_MANIFEST_URL = '$($ctx.ManifestUrl)'
& '$updatePs1'
exit `$LASTEXITCODE
"@
    $updateBootstrapFile = Join-Path $logDir 'no-downgrade-update-bootstrap.ps1'
    [IO.File]::WriteAllBytes($updateBootstrapFile,
                              [Text.UTF8Encoding]::new($false).GetBytes($updateBootstrap))
    $updateOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updateBootstrapFile 2>&1
    $updateRc = $LASTEXITCODE
    Assert-True ($updateRc -eq 0) "update.ps1 must exit 0 when refusing downgrade (got $updateRc; out: $($updateOut -join ' / '))"
    Assert-FileContains (Join-Path $inst '.negativezone-version') '^1\.1\.0' `
        'update.ps1 must NOT downgrade from v1.1.0 to v1.0.0 without opt-in'
    $joined = ($updateOut -join "`n")
    Assert-True ($joined -match 'refusing to downgrade') `
        "update.ps1 must explain it refused the downgrade. Output: $joined"

    # Step 3: re-publish v1.0.0 WITH allowDowngrade:true — both setup.ps1
    # and update.ps1 must now perform the rollback.
    $ctx.PublishVersion.Invoke('1.0.0', $true)
    $r3 = Invoke-SetupPs1 -AppData $appData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label 'no-down-3'
    Assert-True ($r3.ExitCode -eq 0) "v1.0.0 admin-approved rollback must succeed"
    Assert-FileContains (Join-Path $inst '.negativezone-version') '^1\.0\.0' `
        'setup.ps1 must downgrade when allowDowngrade:true'

    $ctx.PublishVersion.Invoke('1.0.0')  # reset (clear allowDowngrade flag)
}

# ─── Main ───────────────────────────────────────────────────────────────────

Write-Section 'NegativeZone setup.ps1 E2E harness'
Write-Info "Repo:    $repoRoot"
Write-Info "Sandbox: $sandbox"

# Stage published artifacts. Standalone .ps1 mirrors are served at the same
# host so Set-PrismCommandHook downloads them off the local server too.
# (Set-PrismCommandHook ALWAYS re-downloads to heal corrupted on-disk copies.)
$instanceName = 'Craft to Exile 2'
$currentZipName = "c2e2-v1.0.0.zip"
Copy-Item -LiteralPath $updatePs1         -Destination (Join-Path $blobDir 'update.ps1')         -Force
Copy-Item -LiteralPath $backupPs1         -Destination (Join-Path $blobDir 'backup.ps1')         -Force
Copy-Item -LiteralPath $prelaunchCheckPs1 -Destination (Join-Path $blobDir 'prelaunch-check.ps1') -Force
# latest-version.txt is the GitHub-hosted version pointer prelaunch-check.ps1
# polls every launch. Harness re-writes this between tests to simulate "admin
# published a new version" without touching Azure.
[IO.File]::WriteAllBytes((Join-Path $blobDir 'latest-version.txt'),
                          [Text.UTF8Encoding]::new($false).GetBytes("1.0.0`n"))
# Serve setup.ps1 itself so the bootstrap can `iex (irm ...)` it the same way
# real users do via the README one-liner. Critical because setup.ps1 contains
# UTF-8 em-dashes without a BOM (lint-ps1.yml enforces no-BOM) and PowerShell
# 5.1 invoked with -File reads scripts as Windows-1252 by default, which
# corrupts the bytes and breaks parsing. The irm path decodes as UTF-8.
Copy-Item -LiteralPath $setupPs1 -Destination (Join-Path $blobDir 'setup.ps1') -Force
$null = Build-FakeModpackZip -Version '1.0.0' -OutDir $blobDir
$null = Build-FakeModpackZip -Version '1.1.0' -OutDir $blobDir

$server = Start-NzHttpServer -ServeDir $blobDir
Write-Info "HTTP:    $($server.BaseUrl)"

# Allow tests to swap which version the latest.json points at, optionally
# with the allowDowngrade opt-in flag set so downgrade-rollback tests can
# prove that path works end-to-end.
$publishVersion = {
    param([string]$v, [switch]$AllowDowngrade)
    Write-Manifest -Version $v -InstanceName $instanceName -BlobName "c2e2-v$v.zip" `
                   -ZipPath (Join-Path $blobDir "c2e2-v$v.zip") `
                   -OutPath (Join-Path $blobDir 'latest.json') `
                   -BaseUrl $server.BaseUrl `
                   -AllowDowngrade:$AllowDowngrade
    # Also rewrite the GitHub-hosted pointer to match. This is what
    # publish-prism-pack.ps1 will do for real (in the same git commit as
    # the docker-compose.yml bump). Tests that need them OUT of sync
    # (e.g. prelaunch-blocks-when-stale) can call BumpLatestVersion
    # independently after this.
    [IO.File]::WriteAllBytes((Join-Path $blobDir 'latest-version.txt'),
                              [Text.UTF8Encoding]::new($false).GetBytes("$v`n"))
}
$publishVersion.Invoke('1.0.0')

# Smoke-test the HTTP server before running tests. If this fails, every
# downstream test would fail with the same root cause — better to surface
# it once, at the top, with a clear message.
Write-Section 'Self-test: HTTP server'
$smoke = Invoke-RestMethod -UseBasicParsing -Uri "$($server.BaseUrl)latest.json"
if ($smoke -is [string]) {
    throw "HTTP server returned manifest as a raw string (Content-Type negotiation broken). Got: $smoke"
}
if (-not $smoke.version) {
    throw "HTTP server returned manifest with empty .version. Raw: $($smoke | ConvertTo-Json -Compress)"
}
Write-Info "    manifest parsed: version=$($smoke.version) url=$($smoke.url)"
$setupSmoke = Invoke-RestMethod -UseBasicParsing -Uri "$($server.BaseUrl)setup.ps1"
if ($setupSmoke -isnot [string] -or $setupSmoke.Length -lt 1000) {
    throw "HTTP server returned setup.ps1 as type [$($setupSmoke.GetType().Name)] length=$($setupSmoke.Length); expected long string."
}
Write-Info "    setup.ps1 fetched: $($setupSmoke.Length) chars, starts: $($setupSmoke.Substring(0, 80))"

$ctx = [pscustomobject]@{
    ManifestUrl              = "$($server.BaseUrl)latest.json"
    UpdateUrl                = "$($server.BaseUrl)update.ps1"
    BackupUrl                = "$($server.BaseUrl)backup.ps1"
    PrelaunchCheckUrl        = "$($server.BaseUrl)prelaunch-check.ps1"
    LatestVersionUrl         = "$($server.BaseUrl)latest-version.txt"
    SetupUrl                 = "$($server.BaseUrl)setup.ps1"
    BlobBaseUrl              = $server.BaseUrl
    PublishVersion           = $publishVersion
    Sandbox                  = $sandbox
    # Mutates the GitHub-hosted version pointer (locally). Mirrors what
    # publish-prism-pack.ps1 would commit to docs/assets/latest-version.txt.
    BumpLatestVersion        = {
        param([string]$v)
        [IO.File]::WriteAllBytes((Join-Path $blobDir 'latest-version.txt'),
                                  [Text.UTF8Encoding]::new($false).GetBytes("$v`n"))
    }
}

# Thin wrapper so the 14+ existing Register-Test bodies don't all need to
# pass the new prelaunch-check + version-pointer URLs explicitly. New URLs
# default to whatever's in $ctx; tests that need to point one elsewhere
# (e.g. "what if latest-version.txt is unreachable") can still call
# Invoke-SetupPs1 directly with -LatestVersionUrl 'http://127.0.0.1:1/404'.
function Invoke-SetupFromCtx {
    param(
        [Parameter(Mandatory)][string] $AppData,
        [Parameter(Mandatory)][string] $Label,
        [string] $LatestVersionUrl,
        [string] $PrelaunchCheckScriptUrl
    )
    if (-not $PrelaunchCheckScriptUrl) { $PrelaunchCheckScriptUrl = $ctx.PrelaunchCheckUrl }
    if (-not $LatestVersionUrl)         { $LatestVersionUrl         = $ctx.LatestVersionUrl }
    return Invoke-SetupPs1 -AppData $AppData -ManifestUrl $ctx.ManifestUrl `
        -UpdateScriptUrl $ctx.UpdateUrl -BackupScriptUrl $ctx.BackupUrl `
        -PrelaunchCheckScriptUrl $ctx.PrelaunchCheckUrl -LatestVersionUrl $ctx.LatestVersionUrl `
        -PrelaunchCheckScriptUrl $PrelaunchCheckScriptUrl `
        -LatestVersionUrl $LatestVersionUrl `
        -SetupUrl $ctx.SetupUrl -Label $Label
}

$ran = 0; $passed = 0; $failed = @()
try {
    foreach ($t in $script:tests) {
        if ($Only -and ($t.Name -notlike "*$Only*")) { continue }
        $ran++
        Write-Section "TEST: $($t.Name)"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            & $t.Body $ctx
            $sw.Stop()
            Write-Host ("    [PASS] {0} ({1} ms)" -f $t.Name, $sw.ElapsedMilliseconds) -ForegroundColor Green
            $passed++
        } catch {
            $sw.Stop()
            Write-Host ("    [FAIL] {0} ({1} ms)" -f $t.Name, $sw.ElapsedMilliseconds) -ForegroundColor Red
            Write-Host ("        $($_.Exception.Message)") -ForegroundColor Red
            if ($_.ScriptStackTrace) {
                # PS 5.1 has no Join-String — keep it manual + simple.
                $stack = ($_.ScriptStackTrace -split "`n" | Select-Object -First 4 | ForEach-Object { '          ' + $_.Trim() }) -join "`n"
                Write-Host $stack -ForegroundColor DarkRed
            }
            # Surface last subprocess log on failure so we can see what setup.ps1
            # actually printed inside the subprocess — without this every test
            # failure becomes a guessing game.
            $latestOut = Get-ChildItem -LiteralPath $logDir -Filter '*.stdout.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $latestErr = Get-ChildItem -LiteralPath $logDir -Filter '*.stderr.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            foreach ($pair in @(
                @{Label='STDOUT'; File=$latestOut},
                @{Label='STDERR'; File=$latestErr}
            )) {
                if ($pair.File -and (Get-Item -LiteralPath $pair.File.FullName).Length -gt 0) {
                    Write-Host ("        --- last subprocess {0} ({1}) ---" -f $pair.Label, $pair.File.Name) -ForegroundColor DarkYellow
                    Get-Content -LiteralPath $pair.File.FullName -Tail 40 | ForEach-Object { Write-Host "          $_" -ForegroundColor DarkGray }
                    Write-Host ("        --- end {0} ---" -f $pair.Label) -ForegroundColor DarkYellow
                }
            }
            $failed += $t.Name
        }
    }
} finally {
    Stop-NzHttpServer -Server $server
    Start-Sleep -Milliseconds 200
    if (-not $KeepSandbox) {
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host ''
        Write-Host "Sandbox preserved: $sandbox" -ForegroundColor Yellow
    }
}

Write-Section "RESULT: $passed/$ran passed"
if ($failed.Count -gt 0) {
    Write-Host ("FAILED: " + ($failed -join ', ')) -ForegroundColor Red
    exit 1
}
exit 0
