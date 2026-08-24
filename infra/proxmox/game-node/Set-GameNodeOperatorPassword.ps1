#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $SourceHost = 'palworld',
    [Parameter(Mandatory = $true)]
    [string] $TargetHost,
    [ValidatePattern('^[a-z_][a-z0-9_-]*$')]
    [string] $User = 'birdo'
)

$ErrorActionPreference = 'Stop'

function Invoke-SshText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $HostAlias,
        [Parameter(Mandatory = $true)]
        [string] $Command
    )

    $output = & ssh -o BatchMode=yes -o ConnectTimeout=15 $HostAlias $Command
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed on ${HostAlias}."
    }
    return ($output | Out-String).Trim()
}

$passwordHash = Invoke-SshText -HostAlias $SourceHost -Command (
    "sudo -n getent shadow $User | cut -d: -f2"
)
if ([string]::IsNullOrWhiteSpace($passwordHash) -or
    $passwordHash -in @('!', '*', '!!')) {
    throw "Source account '$User' is missing or locked on $SourceHost."
}

Invoke-SshText -HostAlias $TargetHost -Command @"
set -eu
id $User >/dev/null
if sudo -n fuser /etc/.pwd.lock >/dev/null 2>&1; then
  echo 'Password database is busy' >&2
  exit 1
fi
sudo -n rm -f /etc/.pwd.lock
"@ | Out-Null

$ssh = (Get-Command ssh -ErrorAction Stop).Source
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $ssh
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($argument in @(
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=15',
    $TargetHost,
    'sudo -n chpasswd -e'
)) {
    [void] $startInfo.ArgumentList.Add($argument)
}

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
[void] $process.Start()
$process.StandardInput.Write("${User}:$passwordHash`n")
$process.StandardInput.Close()
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()
if ($process.ExitCode -ne 0) {
    throw "Password transfer failed on ${TargetHost}: $stderr"
}

Invoke-SshText -HostAlias $TargetHost -Command (
    "sudo -n passwd -n 0 -x 99999 -w 7 $User >/dev/null; " +
    'sudo -n sshd -t; sudo -n systemctl reload ssh'
) | Out-Null

$targetHash = Invoke-SshText -HostAlias $TargetHost -Command (
    "sudo -n getent shadow $User | cut -d: -f2"
)
if ($targetHash -ne $passwordHash) {
    throw "Password verification failed on $TargetHost."
}

Write-Host "Verified $User password access on $TargetHost from source $SourceHost."
