@description('Azure region for all resources')
param location string

@description('Key Vault name — must be globally unique, 3-24 chars')
param keyVaultName string

@description('Object ID of the GitHub Actions OIDC service principal. Run bootstrap.sh step 2 then: az ad sp show --id <appClientId> --query id -o tsv')
param githubActionsObjectId string

@description('Environment tag')
param environment string = 'prod'

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultName
  location: location
  tags: { environment: environment }
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true      // Azure RBAC controls access (not legacy access policies)
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForTemplateDeployment: true // Required: allows ARM to read secrets during Bicep deployment
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Grant the GitHub Actions service principal read-only access to secrets.
// Role: Key Vault Secrets User (4633458b-17de-408a-b874-0445c86b69e6)
// Scope: this vault only
// Docs: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide#azure-built-in-roles-for-key-vault-data-plane-operations
resource githubActionsSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, githubActionsObjectId, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User (read-only)
    )
    principalId: githubActionsObjectId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri

// ---------------------------------------------------------------------------
// Populate these secrets before running the first main deployment.
// Run infra/azure/scripts/bootstrap.sh for the complete setup sequence.
//
// Quick reference — set each with:
//   az keyvault secret set --vault-name kv-minecraft-prod \
//     --name <name> --value "<value>"
//
//   vm-admin-username        — Linux user for SSH (e.g. "mcsvc")
//   ssh-public-key           — SSH public key (cat ~/.ssh/id_ed25519.pub)
//   tailscale-auth-key       — Ephemeral TailScale auth key (from tailscale.com/admin/settings/keys)
//   velocity-forwarding-secret — Random string shared between Velocity and all backends
//   rcon-password            — RCON password for the lobby server
//   c2e2-tailscale-ip        — TailScale IP of the Proxmox VM (100.x.x.x)
// ---------------------------------------------------------------------------
