#!/usr/bin/env bash
# infra/azure/scripts/bootstrap.sh
#
# ONE-TIME setup script for the Minecraft Azure infrastructure.
# Run this ONCE from your local machine before the first GitHub Actions deploy.
# After this script completes, fill the TODO values in prod.bicepparam and push.
#
# Prerequisites:
#   - Azure CLI installed and logged in: az login
#   - GitHub CLI installed and authenticated: gh auth login
#   - SSH key pair generated: ssh-keygen -t ed25519 -C "mc-azure-vm"
#   - jq installed (brew install jq  /  apt install jq)
#
# Usage:
#   chmod +x infra/azure/scripts/bootstrap.sh
#   ./infra/azure/scripts/bootstrap.sh
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
#   - Fill prod.bicepparam TODOs (githubActionsObjectId, proxmoxSpObjectId, subscriptionId)
#   - Add GitHub Actions secrets (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
#     TAILSCALE_OAUTH_CLIENT_ID, TAILSCALE_OAUTH_CLIENT_SECRET, DEPLOY_SSH_PRIVATE_KEY,
#     AZURE_VM_TAILSCALE_IP)
#   - Add Portainer environment variables (STORAGE_ACCOUNT from deploy output,
#     AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET from step 8)
#   - Push to main — GitHub Actions handles all subsequent deploys

set -euo pipefail

RESOURCE_GROUP="rg-minecraft-prod"
LOCATION="westus"
KV_NAME="kv-minecraft-prod"
GITHUB_REPO="camcast3/MinecraftInfra"   # <org>/<repo>
OIDC_APP_NAME="sp-minecraft-github-actions"
PROXMOX_SP_NAME="sp-mc-proxmox-backup"
SSH_PUBLIC_KEY_FILE="${HOME}/.ssh/id_ed25519.pub"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Minecraft Azure Bootstrap"
echo "  Subscription: ${SUBSCRIPTION_ID}"
echo "  Tenant:       ${TENANT_ID}"
echo "════════════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Resource Group ─────────────────────────────────────────────────────
echo "▶ Step 1: Creating resource group '${RESOURCE_GROUP}' in ${LOCATION}..."
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --tags environment=prod \
  --output none
echo "  ✓ Resource group ready."
echo ""

# ── Step 2: GitHub Actions App Registration + Service Principal ────────────────
echo "▶ Step 2: Creating App Registration '${OIDC_APP_NAME}' for GitHub Actions OIDC..."

# Check if app already exists
OIDC_APP_ID=$(az ad app list --display-name "${OIDC_APP_NAME}" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -z "${OIDC_APP_ID}" || "${OIDC_APP_ID}" == "None" ]]; then
  OIDC_APP_ID=$(az ad app create \
    --display-name "${OIDC_APP_NAME}" \
    --query appId -o tsv)
  echo "  ✓ App created: ${OIDC_APP_ID}"
else
  echo "  ✓ App already exists: ${OIDC_APP_ID}"
fi

# Create service principal for the app if it doesn't exist
az ad sp create --id "${OIDC_APP_ID}" --output none 2>/dev/null || true

OIDC_SP_OBJECT_ID=$(az ad sp show --id "${OIDC_APP_ID}" --query id -o tsv)
echo "  ✓ Service principal object ID: ${OIDC_SP_OBJECT_ID}"
echo ""

# ── Step 3: Federated Credential (OIDC) ───────────────────────────────────────
echo "▶ Step 3: Adding federated credential for GitHub Actions OIDC..."

# The workflow uses 'environment: production' — GitHub's OIDC subject for environment
# deployments is 'repo:<org>/<repo>:environment:<name>', regardless of trigger type
# (push to main or workflow_dispatch). One credential covers both.
az ad app federated-credential create \
  --id "${OIDC_APP_ID}" \
  --parameters "{
    \"name\": \"github-actions-prod-env\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_REPO}:environment:production\",
    \"description\": \"GitHub Actions (production environment)\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none 2>/dev/null || echo "  ℹ federated credential 'prod-env' already exists, skipping."

echo "  ✓ Federated credential configured."
echo ""

# ── Step 4: Assign roles to the OIDC SP ───────────────────────────────────────
echo "▶ Step 4: Assigning roles to GitHub Actions SP at RG scope..."
RG_ID=$(az group show --name "${RESOURCE_GROUP}" --query id -o tsv)

# Contributor — deploy resources
az role assignment create \
  --assignee-object-id "${OIDC_SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "${RG_ID}" \
  --output none 2>/dev/null || echo "  ℹ Contributor already assigned."

# User Access Administrator — create role assignments (for MI → KV and MI → Storage)
az role assignment create \
  --assignee-object-id "${OIDC_SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "User Access Administrator" \
  --scope "${RG_ID}" \
  --output none 2>/dev/null || echo "  ℹ User Access Administrator already assigned."

echo "  ✓ Roles assigned."
echo ""

# ── Step 5: Print GitHub Actions values ───────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo "  STEP 5 — Values to record"
echo ""
echo "  ① Fill prod.bicepparam (copy-paste exactly):"
echo "      githubActionsObjectId = '${OIDC_SP_OBJECT_ID}'"
echo "      param adminUsername     = getSecret('${SUBSCRIPTION_ID}', 'rg-minecraft-prod', 'kv-minecraft-prod', 'vm-admin-username')"
echo "      param adminSshPublicKey = getSecret('${SUBSCRIPTION_ID}', 'rg-minecraft-prod', 'kv-minecraft-prod', 'ssh-public-key')"
echo "      param tailscaleAuthKey  = getSecret('${SUBSCRIPTION_ID}', 'rg-minecraft-prod', 'kv-minecraft-prod', 'tailscale-auth-key')"
echo ""
echo "  ② Add these GitHub Actions secrets"
echo "     (Settings → Secrets → Actions → New repository secret):"
echo "      AZURE_CLIENT_ID       = ${OIDC_APP_ID}"
echo "      AZURE_TENANT_ID       = ${TENANT_ID}"
echo "      AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo ""
echo "  Also add later (once available):"
echo "      DEPLOY_SSH_PRIVATE_KEY        — contents of ~/.ssh/id_ed25519"
echo "      AZURE_VM_TAILSCALE_IP         — TailScale IP of the Azure VM (post-deploy)"
echo "      TAILSCALE_OAUTH_CLIENT_ID     — from tailscale.com/admin/settings/oauth"
echo "      TAILSCALE_OAUTH_CLIENT_SECRET — from tailscale.com/admin/settings/oauth"
echo "════════════════════════════════════════════════════════════════"
echo ""

read -r -p "Press Enter to continue to Key Vault setup..."
echo ""

# ── Step 6: Bootstrap-deploy Key Vault ────────────────────────────────────────
echo "▶ Step 6: Deploying Key Vault '${KV_NAME}' (standalone, required for getSecret())..."
az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "$(dirname "$0")/../modules/keyvault.bicep" \
  --parameters \
      location="${LOCATION}" \
      keyVaultName="${KV_NAME}" \
      githubActionsObjectId="${OIDC_SP_OBJECT_ID}" \
  --name "bootstrap-keyvault" \
  --output none
echo "  ✓ Key Vault deployed."
echo ""

# ── Step 7: Populate Key Vault secrets ────────────────────────────────────────
echo "▶ Step 7: Populating Key Vault secrets..."

if [[ ! -f "${SSH_PUBLIC_KEY_FILE}" ]]; then
  echo "  ✗ SSH public key not found at ${SSH_PUBLIC_KEY_FILE}"
  echo "    Run: ssh-keygen -t ed25519 -C 'mc-azure-vm'"
  exit 1
fi

echo "  Setting vm-admin-username..."
az keyvault secret set --vault-name "${KV_NAME}" \
  --name "vm-admin-username" --value "mcsvc" --output none

echo "  Setting ssh-public-key..."
az keyvault secret set --vault-name "${KV_NAME}" \
  --name "ssh-public-key" --value "$(cat "${SSH_PUBLIC_KEY_FILE}")" --output none

echo ""
echo "  The following secrets require manual values — you will be prompted."
echo ""

read -r -p "  TailScale ephemeral auth key (from tailscale.com/admin/settings/keys): " TS_AUTH_KEY
az keyvault secret set --vault-name "${KV_NAME}" \
  --name "tailscale-auth-key" --value "${TS_AUTH_KEY}" --output none

read -r -p "  Velocity forwarding secret (random string, e.g. $(openssl rand -hex 16)): " VELOCITY_SECRET
az keyvault secret set --vault-name "${KV_NAME}" \
  --name "velocity-forwarding-secret" --value "${VELOCITY_SECRET}" --output none

read -r -p "  RCON password (random string, e.g. $(openssl rand -hex 12)): " RCON_PASSWORD
az keyvault secret set --vault-name "${KV_NAME}" \
  --name "rcon-password" --value "${RCON_PASSWORD}" --output none

echo ""
echo "  ℹ Skipping c2e2-tailscale-ip — set this after the Proxmox VM is provisioned:"
echo "    az keyvault secret set --vault-name ${KV_NAME} \\"
echo "      --name c2e2-tailscale-ip --value '100.x.x.x'"
echo ""
echo "  ✓ Key Vault secrets set."
echo ""

# ── Step 8: Proxmox Backup Service Principal ──────────────────────────────────
echo "▶ Step 8: Creating Proxmox backup Service Principal '${PROXMOX_SP_NAME}'..."

PROXMOX_SP_OUTPUT=$(az ad sp create-for-rbac \
  --name "${PROXMOX_SP_NAME}" \
  --output json)

PROXMOX_APP_ID=$(echo "${PROXMOX_SP_OUTPUT}"     | jq -r '.appId')
PROXMOX_CLIENT_SECRET=$(echo "${PROXMOX_SP_OUTPUT}" | jq -r '.password')
PROXMOX_OBJECT_ID=$(az ad sp show --id "${PROXMOX_APP_ID}" --query id -o tsv)

echo "  ✓ Service principal created."
echo ""

# ── Step 9: Print Proxmox values ──────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo "  STEP 9 — Proxmox SP values"
echo ""
echo "  ① Fill prod.bicepparam (NOT a secret — just an identifier):"
echo "      proxmoxSpObjectId = '${PROXMOX_OBJECT_ID}'"
echo ""
echo "  ② Add these to Portainer UI environment variables"
echo "     (NEVER commit these to the repo — they are credentials):"
echo "      AZURE_TENANT_ID       = ${TENANT_ID}"
echo "      AZURE_CLIENT_ID       = ${PROXMOX_APP_ID}"
echo "      AZURE_CLIENT_SECRET   = ${PROXMOX_CLIENT_SECRET}"
echo ""
echo "  ③ After first Bicep deploy, also add to Portainer:"
echo "      STORAGE_ACCOUNT = <read from deploy output>"
echo "      (az deployment group show -g rg-minecraft-prod -n <name>"
echo "       --query properties.outputs.storageAccountName.value -o tsv)"
echo ""
echo "  ④ Other Portainer variables:"
echo "      TS_AUTHKEY                 — from tailscale.com/admin/settings/keys"
echo "      TS_HOSTNAME                = mc-proxmox"
echo "      CF_API_KEY                 — from console.curseforge.com"
echo "      VELOCITY_FORWARDING_SECRET — same value set in KV above"
echo "      RCON_PASSWORD              — same value set in KV above"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  ⚠  SAVE the AZURE_CLIENT_SECRET above — it cannot be retrieved again."
echo "     If lost, run: az ad sp credential reset --id ${PROXMOX_APP_ID}"
echo ""
echo "Bootstrap complete! Next steps:"
echo "  1. Fill prod.bicepparam (githubActionsObjectId, proxmoxSpObjectId, subscriptionId)"
echo "  2. Add GitHub Actions secrets (step 5 above)"
echo "  3. Push to main — CI/CD handles the rest"
