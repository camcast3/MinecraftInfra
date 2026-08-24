#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$templatePath = Join-Path $root 'infra\proxmox\game-node\cloud-init.yaml.tmpl'
$minecraftPath = Join-Path $root 'infra\proxmox\cloud-init.yaml'
$helperPath = Join-Path $root 'infra\proxmox\game-node\Set-GameNodeOperatorPassword.ps1'

$template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
$minecraft = Get-Content -LiteralPath $minecraftPath -Raw -Encoding UTF8
$helper = Get-Content -LiteralPath $helperPath -Raw -Encoding UTF8

foreach ($document in @($template, $minecraft)) {
    foreach ($required in @(
        'useradd --create-home --shell /bin/bash birdo'
        'usermod -aG sudo birdo'
        'birdo ALL=(ALL:ALL) NOPASSWD: ALL'
        'Match User birdo'
        'PasswordAuthentication yes'
        'PubkeyAuthentication yes'
    )) {
        if (-not $document.Contains($required)) {
            throw "Game-node provisioning is missing: $required"
        }
    }
}

if ($template -match '(?im)^\s*(?:password|passwd)\s*:') {
    throw 'Game-node template contains a committed password or password hash.'
}
if ($helper -match 'Write-(?:Host|Output).*passwordHash') {
    throw 'Password transfer helper may print the password hash.'
}
foreach ($required in @(
    'RedirectStandardInput = $true'
    'sudo -n chpasswd -e'
    'sudo -n sshd -t'
    'getent shadow'
)) {
    if (-not $helper.Contains($required)) {
        throw "Password transfer helper is missing: $required"
    }
}

$tokens = $null
$errors = $null
[void] [System.Management.Automation.Language.Parser]::ParseFile(
    $helperPath,
    [ref] $tokens,
    [ref] $errors
)
if ($errors.Count -gt 0) {
    throw "Password transfer helper parse failure: $($errors -join '; ')"
}

Write-Host 'Shared birdo game-node operator policy passed.'
