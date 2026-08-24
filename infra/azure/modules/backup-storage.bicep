@description('Azure region for the dedicated backup storage account.')
param location string

@description('Environment tag.')
param environment string = 'prod'

@description('Dedicated backup storage account name. Must be globally unique, 3-24 lowercase alphanumeric characters.')
@minLength(3)
@maxLength(24)
param storageAccountName string

type backupGame = {
  name: string
  containerName: string
  writerPrincipalId: string
}

@description('One entry per game. Each game receives a private container and a writer scoped only to that container.')
param games backupGame[]

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: storageAccountName
  location: location
  tags: {
    environment: environment
    workload: 'minecraft-backups'
  }
  kind: 'StorageV2'
  sku: {
    name: 'Standard_GRS'
  }
  properties: {
    accessTier: 'Cool'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
  }
}

resource gameContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = [for game in games: {
  parent: blobService
  name: game.containerName
  properties: {
    publicAccess: 'None'
  }
}]

resource gameWriters 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (game, index) in games: {
  // Keep the resource identity stable per container. If an operator attempts
  // to change a writer without first removing the old assignment, Azure fails
  // closed instead of silently retaining both principals under different IDs.
  name: guid(storageAccount.id, game.containerName, storageBlobDataContributorRoleId)
  scope: gameContainers[index]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: game.writerPrincipalId
    principalType: 'ServicePrincipal'
  }
}]

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output containers array = [for (game, index) in games: {
  game: game.name
  name: gameContainers[index].name
  id: gameContainers[index].id
}]
