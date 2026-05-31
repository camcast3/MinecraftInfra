@description('Azure region for all resources')
param location string

@description('Environment tag')
param environment string = 'prod'

@description('Storage account name — must be globally unique, 3-24 lowercase alphanumeric chars. Pinned as a param so it never changes across deploys or RG recreations.')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stmcminecraftprod'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: storageAccountName
  location: location
  tags: { environment: environment }
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // Disable shared key access — all auth must go through Azure RBAC.
    // rclone with Managed Identity (Azure VM) and Service Principal (Proxmox)
    // both use Azure AD tokens and work correctly without shared key access.
    allowSharedKeyAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
}

// Single container for all Minecraft backups.
// Subdirectories (lobby/, c2e2/) are managed by rclone via RCLONE_DEST_DIR in each compose stack.
resource backupsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = {
  parent: blobService
  name: 'minecraft-backups'
  properties: {
    publicAccess: 'None'
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output backupsContainerId string = backupsContainer.id
