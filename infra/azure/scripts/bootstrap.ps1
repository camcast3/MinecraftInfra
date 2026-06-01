#!/usr/bin/env pwsh
# infra/azure/scripts/bootstrap.ps1
#
# ONE-TIME setup script for the Minecraft Azure infrastructure.
# Run this ONCE from PowerShell before the first GitHub Actions deploy.
# After this script completes, fill the TODO values in prod.bicepparam and push.
#
# Prerequisites:
#   - Azure CLI:   winget install Microsoft.AzureCLI
#   - Logged in:   az login
#   - SSH key:     ssh-keygen -t ed25519 -C "mc-azure-vm"
#
# Usage:
#   .\infra\azure\scripts\bootstrap.ps1
#
# What it does (in order):
#   1.  Create resource group rg-minecraft-prod (West US)
#   2.  Create GitHub Actions App Registration + Service Principal (OIDC, no password)
#   3.  Add federated credential for this repo (environment: production)
#   4.  Assign Contributor + User Access Administrator to the OIDC SP at RG scope
#   5.  Print values → fill prod.bicepparam and GitHub Actions secrets
#   6.  Bootstrap-deploy Key Vault only (standalone, required before main.bicep)
#   7.  Populate all Key Vault secrets
#   8.  Create Proxmox backup Service Principal
#   9.  Print values → fill prod.bicepparam (SP object ID) and Portainer UI (credentials)
#
# After this script:
#   - Fill prod.bicepparam TODOs (githubActionsObjectId, proxmoxSpObjectId)
#   - Add GitHub Actions secrets (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID)
#   - Add Portainer environment variables (STORAGE_ACCOUNT from deploy output,
#     AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET from step 8)
#   - Push to main — GitHub Actions handles all subsequent deploys

$ErrorActionPreference = 'Stop'

$RESOURCE_GROUP  = 'rg-minecraft-prod'
$LOCATION        = 'westus'
$KV_NAME         = 'kv-minecraft-prod'
$GITHUB_REPO     = 'camcast3/MinecraftInfra'
$OIDC_APP_NAME   = 'sp-minecraft-github-actions'
$PROXMOX_SP_NAME = 'sp-mc-proxmox-backup'
$SSH_KEY_FILE    = "$env:USERPROFILE\.ssh\id_ed25519.pub"

# Generate a random hex string (no openssl needed)
function New-RandomHex([int]$Bytes = 16) {
    $buf = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buf)
    return -join ($buf | ForEach-Object { $_.ToString('x2') })
}

# Run an az command and throw on non-zero exit
function Invoke-Az {
    param([string[]]$Arguments)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') exited with code $LASTEXITCODE"
    }
    return $output
}

# ── Verify login ──────────────────────────────────────────────────────────────
$SUBSCRIPTION_ID = (& az account show --query id -o tsv 2>&1)
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged in to Azure. Run: az login"
}
$SUBSCRIPTION_ID = $SUBSCRIPTION_ID.Trim()
$TENANT_ID = (Invoke-Az @('account', 'show', '--query', 'tenantId', '-o', 'tsv')).Trim()

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host "  Minecraft Azure Bootstrap"
Write-Host "  Subscription : $SUBSCRIPTION_ID"
Write-Host "  Tenant       : $TENANT_ID"
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host ""

# ── Step 1: Resource Group ────────────────────────────────────────────────────
Write-Host "▶ Step 1: Creating resource group '$RESOURCE_GROUP' in $LOCATION..."
Invoke-Az @('group', 'create',
    '--name',     $RESOURCE_GROUP,
    '--location', $LOCATION,
    '--tags',     'environment=prod',
    '--output',   'none')
Write-Host "  ✓ Resource group ready."
Write-Host ""

# ── Step 2: GitHub Actions App Registration + Service Principal ───────────────
Write-Host "▶ Step 2: Creating App Registration '$OIDC_APP_NAME' for GitHub Actions OIDC..."
$OIDC_APP_ID = (& az ad app list --display-name $OIDC_APP_NAME --query '[0].appId' -o tsv 2>$null) -join '' | ForEach-Object { $_.Trim() }

if ([string]::IsNullOrEmpty($OIDC_APP_ID) -or $OIDC_APP_ID -eq 'None') {
    $OIDC_APP_ID = (Invoke-Az @('ad', 'app', 'create',
        '--display-name', $OIDC_APP_NAME,
        '--query', 'appId', '-o', 'tsv')).Trim()
    Write-Host "  ✓ App created: $OIDC_APP_ID"
} else {
    Write-Host "  ✓ App already exists: $OIDC_APP_ID"
}

# Create SP (idempotent — ignore error if already exists)
& az ad sp create --id $OIDC_APP_ID --output none 2>&1 | Out-Null

$OIDC_SP_OBJECT_ID = (Invoke-Az @('ad', 'sp', 'show',
    '--id', $OIDC_APP_ID, '--query', 'id', '-o', 'tsv')).Trim()
Write-Host "  ✓ Service principal object ID: $OIDC_SP_OBJECT_ID"
Write-Host ""

# ── Step 3: Federated Credential (OIDC) ──────────────────────────────────────
Write-Host "▶ Step 3: Adding federated credential for GitHub Actions OIDC..."

# The workflow uses 'environment: production' — GitHub's OIDC subject for environment
# deployments is 'repo:<org>/<repo>:environment:<name>', regardless of trigger type
# (push to main or workflow_dispatch). One credential covers both.
$fedJson = @{
    name        = 'github-actions-prod-env'
    issuer      = 'https://token.actions.githubusercontent.com'
    subject     = "repo:${GITHUB_REPO}:environment:production"
    description = 'GitHub Actions (production environment)'
    audiences   = @('api://AzureADTokenExchange')
} | ConvertTo-Json -Compress

# Write to a temp file to avoid Windows quoting issues with inline JSON
$tmpJson = [System.IO.Path]::GetTempFileName() + '.json'
$fedJson | Set-Content $tmpJson -Encoding UTF8

& az ad app federated-credential create --id $OIDC_APP_ID --parameters "@$tmpJson" --output none 2>&1 | Out-Null
Remove-Item $tmpJson -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ℹ federated credential already exists, skipping."
} else {
    Write-Host "  ✓ Federated credential configured."
}
Write-Host ""

# ── Step 4: Assign roles to the OIDC SP ──────────────────────────────────────
Write-Host "▶ Step 4: Assigning roles to GitHub Actions SP at RG scope..."
$RG_ID = (Invoke-Az @('group', 'show', '--name', $RESOURCE_GROUP, '--query', 'id', '-o', 'tsv')).Trim()

# Contributor — deploy resources
& az role assignment create `
    --assignee-object-id $OIDC_SP_OBJECT_ID `
    --assignee-principal-type ServicePrincipal `
    --role 'Contributor' `
    --scope $RG_ID `
    --output none 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "  ℹ Contributor already assigned." }
else { Write-Host "  ✓ Contributor assigned." }

# User Access Administrator — create role assignments (for MI → KV and MI → Storage)
& az role assignment create `
    --assignee-object-id $OIDC_SP_OBJECT_ID `
    --assignee-principal-type ServicePrincipal `
    --role 'User Access Administrator' `
    --scope $RG_ID `
    --output none 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "  ℹ User Access Administrator already assigned." }
else { Write-Host "  ✓ User Access Administrator assigned." }
Write-Host ""

# ── Step 5: Print GitHub Actions values ──────────────────────────────────────
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host "  STEP 5 — Values to record"
Write-Host ""
Write-Host "  ① Fill prod.bicepparam (copy-paste exactly):"
Write-Host "      githubActionsObjectId = '$OIDC_SP_OBJECT_ID'"
Write-Host "      param adminUsername     = getSecret('$SUBSCRIPTION_ID', 'rg-minecraft-prod', 'kv-minecraft-prod', 'vm-admin-username')"
Write-Host "      param adminSshPublicKey = getSecret('$SUBSCRIPTION_ID', 'rg-minecraft-prod', 'kv-minecraft-prod', 'ssh-public-key')"
Write-Host "      param tailscaleAuthKey  = getSecret('$SUBSCRIPTION_ID', 'rg-minecraft-prod', 'kv-minecraft-prod', 'tailscale-auth-key')"
Write-Host ""
Write-Host "  ② Add these GitHub Actions secrets"
Write-Host "     (Settings → Secrets → Actions → New repository secret):"
Write-Host "      AZURE_CLIENT_ID       = $OIDC_APP_ID"
Write-Host "      AZURE_TENANT_ID       = $TENANT_ID"
Write-Host "      AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host ""
Read-Host "Press Enter to continue to Key Vault setup"
Write-Host ""

# ── Step 6: Bootstrap-deploy Key Vault ───────────────────────────────────────
Write-Host "▶ Step 6: Deploying Key Vault '$KV_NAME' (standalone, required for getSecret())..."
$kvTemplatePath = Join-Path $PSScriptRoot '..\modules\keyvault.bicep'
Invoke-Az @('deployment', 'group', 'create',
    '--resource-group',  $RESOURCE_GROUP,
    '--template-file',   $kvTemplatePath,
    '--parameters',      "location=$LOCATION",
    '--parameters',      "keyVaultName=$KV_NAME",
    '--parameters',      "githubActionsObjectId=$OIDC_SP_OBJECT_ID",
    '--name',            'bootstrap-keyvault',
    '--output',          'none')
Write-Host "  ✓ Key Vault deployed."
Write-Host ""

# ── Step 6b: Grant bootstrap operator write access to Key Vault ──────────────
Write-Host "▶ Step 6b: Granting Key Vault Secrets Officer to current user..."
$CURRENT_USER_OID = (& az ad signed-in-user show --query id -o tsv 2>$null) -join '' | ForEach-Object { $_.Trim() }
$KV_RESOURCE_ID = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KV_NAME"
& az role assignment create `
    --assignee-object-id $CURRENT_USER_OID `
    --assignee-principal-type User `
    --role 'Key Vault Secrets Officer' `
    --scope $KV_RESOURCE_ID `
    --output none 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "  ℹ Role already assigned." }
else { Write-Host "  ✓ Key Vault Secrets Officer granted to current user." }

# RBAC assignments can take up to 60 s to propagate
Write-Host "  ⏳ Waiting 60 s for RBAC propagation..."
Start-Sleep -Seconds 60
Write-Host ""

# ── Step 7: Populate Key Vault secrets ───────────────────────────────────────
Write-Host "▶ Step 7: Populating Key Vault secrets..."

if (-not (Test-Path $SSH_KEY_FILE)) {
    Write-Error "SSH public key not found at '$SSH_KEY_FILE'. Run: ssh-keygen -t ed25519 -C 'mc-azure-vm'"
}
$sshPublicKey = (Get-Content $SSH_KEY_FILE -Raw).Trim()

Write-Host "  Setting vm-admin-username..."
Invoke-Az @('keyvault', 'secret', 'set',
    '--vault-name', $KV_NAME, '--name', 'vm-admin-username', '--value', 'mcsvc', '--output', 'none')

Write-Host "  Setting ssh-public-key..."
Invoke-Az @('keyvault', 'secret', 'set',
    '--vault-name', $KV_NAME, '--name', 'ssh-public-key', '--value', $sshPublicKey, '--output', 'none')

Write-Host ""
Write-Host "  The following secrets require manual values — you will be prompted."
Write-Host ""

$TS_AUTH_KEY = Read-Host "  TailScale ephemeral auth key (from tailscale.com/admin/settings/keys)"
Invoke-Az @('keyvault', 'secret', 'set',
    '--vault-name', $KV_NAME, '--name', 'tailscale-auth-key', '--value', $TS_AUTH_KEY, '--output', 'none')

$velocitySuggestion = New-RandomHex -Bytes 16
$VELOCITY_SECRET = Read-Host "  Velocity forwarding secret [press Enter to use: $velocitySuggestion]"
if ([string]::IsNullOrWhiteSpace($VELOCITY_SECRET)) { $VELOCITY_SECRET = $velocitySuggestion }
Invoke-Az @('keyvault', 'secret', 'set',
    '--vault-name', $KV_NAME, '--name', 'velocity-forwarding-secret', '--value', $VELOCITY_SECRET, '--output', 'none')

$rconSuggestion = New-RandomHex -Bytes 12
$RCON_PASSWORD = Read-Host "  RCON password [press Enter to use: $rconSuggestion]"
if ([string]::IsNullOrWhiteSpace($RCON_PASSWORD)) { $RCON_PASSWORD = $rconSuggestion }
Invoke-Az @('keyvault', 'secret', 'set',
    '--vault-name', $KV_NAME, '--name', 'rcon-password', '--value', $RCON_PASSWORD, '--output', 'none')

Write-Host ""
Write-Host "  ℹ Skipping c2e2-tailscale-ip — set this after the Proxmox VM is provisioned:"
Write-Host "    az keyvault secret set --vault-name $KV_NAME ``"
Write-Host "      --name c2e2-tailscale-ip --value '100.x.x.x'"
Write-Host ""
Write-Host "  ✓ Key Vault secrets set."
Write-Host ""

# ── Step 8: Proxmox Backup Service Principal ─────────────────────────────────
Write-Host "▶ Step 8: Creating Proxmox backup Service Principal '$PROXMOX_SP_NAME'..."
$proxmoxSpJson = Invoke-Az @('ad', 'sp', 'create-for-rbac',
    '--name', $PROXMOX_SP_NAME, '--output', 'json')
$proxmoxSp = $proxmoxSpJson | ConvertFrom-Json

$PROXMOX_APP_ID        = $proxmoxSp.appId
$PROXMOX_CLIENT_SECRET = $proxmoxSp.password
$PROXMOX_OBJECT_ID     = (Invoke-Az @('ad', 'sp', 'show',
    '--id', $PROXMOX_APP_ID, '--query', 'id', '-o', 'tsv')).Trim()

Write-Host "  ✓ Service principal created."
Write-Host ""

# ── Step 9: Print Proxmox values ──────────────────────────────────────────────
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host "  STEP 9 — Proxmox SP values"
Write-Host ""
Write-Host "  ① Fill prod.bicepparam (NOT a secret — just an identifier):"
Write-Host "      proxmoxSpObjectId = '$PROXMOX_OBJECT_ID'"
Write-Host ""
Write-Host "  ② Add these to Portainer UI environment variables"
Write-Host "     (NEVER commit these to the repo — they are credentials):"
Write-Host "      AZURE_TENANT_ID       = $TENANT_ID"
Write-Host "      AZURE_CLIENT_ID       = $PROXMOX_APP_ID"
Write-Host "      AZURE_CLIENT_SECRET   = $PROXMOX_CLIENT_SECRET"
Write-Host ""
Write-Host "  ③ After first Bicep deploy, also add to Portainer:"
Write-Host "      STORAGE_ACCOUNT = <read from deploy output>"
Write-Host "      (az deployment group show -g rg-minecraft-prod -n <deploy-name>"
Write-Host "       --query properties.outputs.storageAccountName.value -o tsv)"
Write-Host ""
Write-Host "  ④ Other Portainer variables:"
Write-Host "      TS_AUTHKEY                 — from tailscale.com/admin/settings/keys"
Write-Host "      TS_HOSTNAME                = mc-proxmox"
Write-Host "      CF_API_KEY                 — from console.curseforge.com"
Write-Host "      VELOCITY_FORWARDING_SECRET — same value set in KV above"
Write-Host "      RCON_PASSWORD              — same value set in KV above"
Write-Host "════════════════════════════════════════════════════════════════"
Write-Host ""
Write-Host "  ⚠  SAVE the AZURE_CLIENT_SECRET above — it cannot be retrieved again."
Write-Host "     If lost, run: az ad sp credential reset --id $PROXMOX_APP_ID"
Write-Host ""
Write-Host "Bootstrap complete! Next steps:"
Write-Host "  1. Fill prod.bicepparam (githubActionsObjectId, proxmoxSpObjectId)"
Write-Host "  2. Add GitHub Actions secrets (step 5 above)"
Write-Host "  3. Push to main — CI/CD handles the rest"
