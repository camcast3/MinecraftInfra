targetScope = 'resourceGroup'

@description('Azure region — set to westus in prod.bicepparam')
param location string

@description('Key Vault name (globally unique)')
param keyVaultName string

@description('Object ID of the GitHub Actions OIDC service principal. Run bootstrap.sh step 2 then: az ad sp show --id <appClientId> --query id -o tsv')
param githubActionsObjectId string

@description('Object ID of the Proxmox backup service principal (NOT a secret — just an identifier). Run bootstrap.sh step 7 then: az ad sp show --id <proxmoxAppClientId> --query id -o tsv')
param proxmoxSpObjectId string

@description('Admin username on the VM — resolved from Key Vault by ARM')
@secure()
param adminUsername string

@description('SSH public key — pulled from Key Vault by ARM, never seen by the runner')
@secure()
param adminSshPublicKey string

@description('TailScale auth key — pulled from Key Vault by ARM, never seen by the runner')
@secure()
param tailscaleAuthKey string

@description('Email address for budget alerts — pulled from Key Vault by ARM, never seen by the runner')
@secure()
param alertEmail string

@description('VM size')
param vmSize string = 'Standard_B4s_v2'

@description('Environment tag')
param environment string = 'prod'

@description('Storage account name — must be globally unique, 3-24 lowercase alphanumeric. Set explicitly so it never changes across deploys or RG recreations.')
param storageAccountName string = 'stmcminecraftprod'

// Azure built-in role definition IDs (stable GUIDs, same across all tenants)
var keyVaultSecretsUserRoleId      = '4633458b-17de-408a-b874-0445c86b69e6'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

// ── Key Vault ──────────────────────────────────────────────────────────────────
// Deployed independently of VM so ARM can resolve getSecret() on all subsequent runs.
// See bootstrap.sh for one-time vault creation and secret population.
module keyVault 'modules/keyvault.bicep' = {
  name: 'deploy-keyvault'
  params: {
    location: location
    keyVaultName: keyVaultName
    githubActionsObjectId: githubActionsObjectId
    environment: environment
  }
}

// ── Networking ─────────────────────────────────────────────────────────────────
module network 'modules/network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    environment: environment
  }
}

// ── VM + System-Assigned Managed Identity ─────────────────────────────────────
module vm 'modules/vm.bicep' = {
  name: 'deploy-vm'
  params: {
    location: location
    nicId: network.outputs.nicId
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    tailscaleAuthKey: tailscaleAuthKey
    vmSize: vmSize
    environment: environment
  }
}

// ── Storage Account + Backup Container ────────────────────────────────────────
module storage 'modules/storage.bicep' = {
  name: 'deploy-storage'
  params: {
    location: location
    environment: environment
    storageAccountName: storageAccountName
  }
}

// ── Budget + Alerts ───────────────────────────────────────────────────────────
module budget 'modules/budget.bicep' = {
  name: 'deploy-budget'
  params: {
    alertEmail: alertEmail
    environment: environment
  }
}

// ── Cross-Resource Role Assignments ───────────────────────────────────────────
// Kept here (not inside individual modules) so each module can deploy in parallel
// without ordering constraints on each other.
//
// Implicit dependencies are created by referencing module outputs in resource
// properties, so ARM automatically orders: modules → role assignments.

// Existing resource references needed for role assignment scopes
resource kvScope 'Microsoft.KeyVault/vaults@2025-05-01' existing = {
  name: keyVaultName
}

resource storageScope 'Microsoft.Storage/storageAccounts@2025-08-01' existing = {
  name: storageAccountName
}

resource blobServiceScope 'Microsoft.Storage/storageAccounts/blobServices@2025-08-01' existing = {
  name: 'default'
  parent: storageScope
}

resource backupsContainerScope 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' existing = {
  name: 'minecraft-backups'
  parent: blobServiceScope
}

// VM MI → Key Vault Secrets User
// Allows the VM to read KV secrets at runtime (e.g., emergency key rotation without CI/CD)
resource vmMiKvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // guid() is deterministic — re-running this deployment is idempotent
  name: guid(keyVaultName, resourceGroup().id, 'vm-mi-kv-secrets-user')
  scope: kvScope
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: vm.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// VM MI → Storage Blob Data Contributor (minecraft-backups container only)
// Enables rclone on the Azure VM to write backups using the Managed Identity —
// no credentials needed, rclone uses RCLONE_CONFIG_AZBLOB_ENV_AUTH=true
resource vmMiStorageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountName, resourceGroup().id, 'vm-mi-storage-blob-contributor')
  scope: backupsContainerScope
  dependsOn: [storage]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: vm.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// Proxmox SP → Storage Blob Data Contributor (minecraft-backups container only)
// Enables rclone on the Proxmox VM to write backups using client_id/client_secret
// stored as Portainer env vars (AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID)
resource proxmoxSpStorageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountName, proxmoxSpObjectId, 'proxmox-sp-storage-blob-contributor')
  scope: backupsContainerScope
  dependsOn: [storage]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: proxmoxSpObjectId
    principalType: 'ServicePrincipal'
  }
}

output publicIpAddress string = network.outputs.publicIpAddress
output publicIpFqdn string = network.outputs.publicIpFqdn
output keyVaultUri string = keyVault.outputs.keyVaultUri
// Read after first deploy to populate prod.bicepparam and Portainer env vars:
//   az deployment group show -g rg-minecraft-prod -n <name> \
//     --query properties.outputs.storageAccountName.value -o tsv
output storageAccountName string = storage.outputs.storageAccountName
output vmPrincipalId string = vm.outputs.principalId
