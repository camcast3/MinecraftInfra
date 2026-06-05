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
    // Anonymous blob reads are allowed at the account level so the
    // `minecraft-modpack` container below can serve the exported Prism
    // instance zip to player setup.ps1 without credentials. The
    // `minecraft-backups` container keeps publicAccess: 'None' and stays
    // RBAC-only — public access is opt-in per container.
    allowBlobPublicAccess: true
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

// Public-read container for the exported Prism Launcher instance zip.
// Player setup.ps1 pulls `latest.json` + the versioned zip from here anonymously,
// skipping the slow CurseForge download path. Re-uploaded by
// scripts/publish-prism-pack.ps1 whenever the modpack is updated.
//
// publicAccess: 'Blob' = anonymous read on individual blobs (NOT directory listing).
// Containers are not enumerable; users must know the exact blob name.
resource modpackContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = {
  parent: blobService
  name: 'minecraft-modpack'
  properties: {
    publicAccess: 'Blob'
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output backupsContainerId string = backupsContainer.id
output modpackContainerId string = modpackContainer.id
