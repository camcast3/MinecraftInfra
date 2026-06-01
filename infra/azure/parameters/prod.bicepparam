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
param githubActionsObjectId = '61e7a20a-84f5-4a4d-b5d8-83d099953e36'

// Object ID of the Proxmox backup service principal (NOT a secret — just an identifier).
// Run bootstrap.sh step 7, then:
//   az ad sp show --id <proxmoxAppClientId> --query id -o tsv
param proxmoxSpObjectId = 'aadced53-d6f8-4430-bc48-af7a29caa418'

// ── Secrets from Key Vault ────────────────────────────────────────────────────
// ARM resolves getSecret() directly — the GitHub Actions runner never sees these values.
// Run bootstrap.sh to populate all secrets before the first deployment.
param adminUsername     = getSecret('0647ab84-e864-4016-8ea8-59dc13b347d4', 'rg-minecraft-prod', 'kv-minecraft-prod', 'vm-admin-username')
param adminSshPublicKey = getSecret('0647ab84-e864-4016-8ea8-59dc13b347d4', 'rg-minecraft-prod', 'kv-minecraft-prod', 'ssh-public-key')
param tailscaleAuthKey  = getSecret('0647ab84-e864-4016-8ea8-59dc13b347d4', 'rg-minecraft-prod', 'kv-minecraft-prod', 'tailscale-auth-key')
