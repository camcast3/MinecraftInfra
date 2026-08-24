@description('Azure region for all resources')
param location string

@description('Environment tag')
param environment string = 'prod'

@description('Public modpack storage account name — must be globally unique, 3-24 lowercase alphanumeric chars. Pinned so published player URLs remain stable.')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stmcminecraftprod'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: storageAccountName
  location: location
  tags: { environment: environment }
  kind: 'StorageV2'
  sku: { name: 'Standard_GRS' }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    // Anonymous blob reads are allowed only so `minecraft-modpack` can serve
    // player setup artifacts. Backups live in a separate account where public
    // blob access is disabled account-wide.
    allowBlobPublicAccess: true
    allowSharedKeyAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
}

// Public-read container for the exported Prism Launcher instance zip.
// Player nz setup pulls `latest.json` + the versioned zip from here anonymously,
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
output modpackContainerId string = modpackContainer.id
