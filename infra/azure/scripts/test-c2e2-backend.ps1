#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9.+_-]+$')]
    [string] $ExpectedVersion,
    [string] $ResourceGroup = 'rg-minecraft-prod',
    [string] $VmName = 'vm-minecraft-prod'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$remoteScript = @'
set -euo pipefail
EXPECTED="${1#expectedVersion=}"
case "$EXPECTED" in
  "" | *[!a-zA-Z0-9.+_-]*)
    echo "Unsafe or empty expected version" >&2
    exit 1
    ;;
esac

CONFIG=/data/minecraft/velocity/velocity.toml
BACKEND="$(sed -n 's/^[[:space:]]*c2e2[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -n 1)"
if [ -z "$BACKEND" ] || [ "${BACKEND#*:}" = "$BACKEND" ]; then
  echo "Could not resolve C2E2 backend from $CONFIG" >&2
  exit 1
fi

HOST="${BACKEND%:*}"
PORT="${BACKEND##*:}"
STATUS="$(docker exec velocity mc-monitor status -host "$HOST" -port "$PORT" -json)"
printf '%s\n' "$STATUS"
printf '%s' "$STATUS" | grep -F "v$EXPECTED" >/dev/null
echo "C2E2_BACKEND_HEALTH_OK"
'@

$json = & az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunShellScript `
    --parameters "expectedVersion=$ExpectedVersion" `
    --scripts $remoteScript `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw "Azure run-command invocation failed with exit code $LASTEXITCODE."
}

$result = $json | ConvertFrom-Json
$message = @($result.value | ForEach-Object { $_.message }) -join "`n"
Write-Host $message
if ($message -notmatch '(?m)^C2E2_BACKEND_HEALTH_OK\s*$') {
    throw 'C2E2 backend health marker was not returned by the Azure VM.'
}
