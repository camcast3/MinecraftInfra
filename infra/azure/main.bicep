targetScope = 'resourceGroup'

@description('Azure region — set to westus in prod.bicepparam')
param location string

@description('Key Vault name (globally unique)')
param keyVaultName string

@description('Object ID of the GitHub Actions OIDC service principal. Run bootstrap.sh step 2 then: az ad sp show --id <appClientId> --query id -o tsv')
param githubActionsObjectId string

@description('Object ID of the Proxmox backup service principal (NOT a secret — just an identifier). Run bootstrap.sh step 7 then: az ad sp show --id <proxmoxAppClientId> --query id -o tsv')
param proxmoxSpObjectId string

@description('Object ID of the distinct Palworld backup writer. Leave empty until that identity exists; never reuse the C2E2 writer.')
param palworldBackupSpObjectId string = ''

@description('Object ID of the distinct Windrose backup writer. Leave empty until that identity exists; never reuse the C2E2 writer.')
param windroseBackupSpObjectId string = ''

@description('Admin username on the VM — resolved from Key Vault by ARM')
@secure()
param adminUsername string

@description('SSH public key — pulled from Key Vault by ARM, never seen by the runner')
@secure()
param adminSshPublicKey string

@description('Email address for budget alerts — pulled from Key Vault by ARM, never seen by the runner')
@secure()
param alertEmail string

@description('VM size')
param vmSize string = 'Standard_B4s_v2'

@description('Environment tag')
param environment string = 'prod'

@description('Whether to send osProfile.customData on the VM. Only set true for an initial provision against an empty resource group — Azure rejects changes to this property on an existing VM.')
param setCustomData bool = false

@description('Storage account name — must be globally unique, 3-24 lowercase alphanumeric. Set explicitly so it never changes across deploys or RG recreations.')
param storageAccountName string = 'stmcminecraftprod'

@description('Dedicated private backup storage account name — must be globally unique, 3-24 lowercase alphanumeric.')
@minLength(3)
@maxLength(24)
param backupStorageAccountName string = 'stmcbackupsprod'

@description('Private backup container dedicated to Craft to Exile 2.')
@minLength(3)
@maxLength(63)
param c2e2BackupContainerName string = 'c2e2-backups'

@description('Private backup container dedicated to Palworld.')
@minLength(3)
@maxLength(63)
param palworldBackupContainerName string = 'palworld-backups'

@description('Private backup container dedicated to Windrose.')
@minLength(3)
@maxLength(63)
param windroseBackupContainerName string = 'windrose-backups'

@description('Backup-account ingress threshold over one hour, in bytes.')
@minValue(1)
param backupIngressThresholdBytes int = 16106127360

@description('Monthly Azure budget amount in USD.')
@minValue(1)
param budgetAmount int = 80

// Azure built-in role definition IDs (stable GUIDs, same across all tenants)
var keyVaultSecretsUserRoleId      = '4633458b-17de-408a-b874-0445c86b69e6'

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
// Tailscale runs as a Docker sidecar (docker/azure/docker-compose.yml), not on
// the host. The auth key is fetched at deploy time by refresh-env.sh from
// Key Vault — no need to inject it into cloud-init or pass it through Bicep.
module vm 'modules/vm.bicep' = {
  name: 'deploy-vm'
  params: {
    location: location
    nicId: network.outputs.nicId
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    vmSize: vmSize
    environment: environment
    setCustomData: setCustomData
  }
}

// ── Public Modpack Storage ────────────────────────────────────────────────────
module storage 'modules/storage.bicep' = {
  name: 'deploy-modpack-storage'
  params: {
    location: location
    environment: environment
    storageAccountName: storageAccountName
  }
}

var backupGames = concat(
  [
    {
      name: 'c2e2'
      containerName: c2e2BackupContainerName
      writerPrincipalId: proxmoxSpObjectId
    }
  ],
  empty(palworldBackupSpObjectId) ? [] : [
    {
      name: 'palworld'
      containerName: palworldBackupContainerName
      writerPrincipalId: palworldBackupSpObjectId
    }
  ],
  empty(windroseBackupSpObjectId) ? [] : [
    {
      name: 'windrose'
      containerName: windroseBackupContainerName
      writerPrincipalId: windroseBackupSpObjectId
    }
  ]
)

// ── Dedicated Private Backup Storage ─────────────────────────────────────────
// The games array is the per-game container/RBAC foundation: add a game with
// its own container and writer identity instead of sharing a broad account role.
module backupStorage 'modules/backup-storage.bicep' = {
  name: 'deploy-backup-storage'
  params: {
    location: location
    environment: environment
    storageAccountName: backupStorageAccountName
    games: backupGames
  }
}

// ── Budget + Alerts ───────────────────────────────────────────────────────────
module budget 'modules/budget.bicep' = {
  name: 'deploy-budget'
  params: {
    alertEmail: alertEmail
    budgetAmount: budgetAmount
    environment: environment
  }
}

// ── Storage Ingress Anomaly Alert ─────────────────────────────────────────────
// The dimensions match the observed rclone path: OAuth + Primary + PutBlock.
// Separating backups from public modpack publishing avoids publish-driven noise.
module metricAlerts 'modules/metric-alerts.bicep' = {
  name: 'deploy-metric-alerts'
  params: {
    storageAccountName: backupStorage.outputs.storageAccountName
    actionGroupId: budget.outputs.actionGroupId
    environment: environment
    ingressThresholdBytes: backupIngressThresholdBytes
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

output publicIpAddress string = network.outputs.publicIpAddress
output publicIpFqdn string = network.outputs.publicIpFqdn
output keyVaultUri string = keyVault.outputs.keyVaultUri
// Read after first deploy to populate prod.bicepparam and Portainer env vars:
//   az deployment group show -g rg-minecraft-prod -n <name> \
//     --query properties.outputs.storageAccountName.value -o tsv
output storageAccountName string = storage.outputs.storageAccountName
output backupStorageAccountName string = backupStorage.outputs.storageAccountName
output backupContainers array = backupStorage.outputs.containers
output vmPrincipalId string = vm.outputs.principalId
