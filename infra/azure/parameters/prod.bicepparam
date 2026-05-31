using '../main.bicep'

// ── Region ───────────────────────────────────────────────────────────────────
param location = 'westus'
param environment = 'prod'
param vmSize = 'Standard_B4s_v2'

// ── Key Vault ─────────────────────────────────────────────────────────────────
// Name must be globally unique (3-24 chars, alphanumeric + hyphens)
param keyVaultName = 'kv-minecraft-prod'

// ── Storage ───────────────────────────────────────────────────────────────────
// Pinned explicitly so the name never changes across deploys or RG recreations.
// Must be globally unique, 3-24 lowercase alphanumeric chars (no hyphens).
// Change this only if the name is already taken — after first deploy, never change it.
param storageAccountName = 'stmcminecraftprod'

// Object ID of the GitHub Actions OIDC service principal.
// Run bootstrap.sh step 2, then:
//   az ad sp show --id <appClientId> --query id -o tsv
param githubActionsObjectId = '' // TODO: fill after running bootstrap.sh

// Object ID of the Proxmox backup service principal (NOT a secret — just an identifier).
// Run bootstrap.sh step 7, then:
//   az ad sp show --id <proxmoxAppClientId> --query id -o tsv
param proxmoxSpObjectId = '' // TODO: fill after running bootstrap.sh

// ── Secrets from Key Vault ────────────────────────────────────────────────────
// ARM resolves getSecret() directly — the GitHub Actions runner never sees these values.
// Run bootstrap.sh to populate all secrets before the first deployment.
param adminUsername    = getSecret('<subscriptionId>', 'rg-minecraft-prod', 'kv-minecraft-prod', 'vm-admin-username')
param adminSshPublicKey = getSecret('<subscriptionId>', 'rg-minecraft-prod', 'kv-minecraft-prod', 'ssh-public-key')
param tailscaleAuthKey  = getSecret('<subscriptionId>', 'rg-minecraft-prod', 'kv-minecraft-prod', 'tailscale-auth-key')
