#!/usr/bin/env bash
# docker/azure/refresh-env.sh
#
# Runs ON the Azure VM. Authenticates via the system-assigned Managed Identity,
# fetches secrets from Key Vault, and writes docker/azure/.env.
#
# Called by the deploy workflow after `git pull`, before `docker compose up`.
# No credentials needed — the VM's MI has Key Vault Secrets User role.
#
# Usage (on the VM):
#   /opt/minecraft/docker/azure/refresh-env.sh

set -euo pipefail

KV_NAME="kv-minecraft-prod"
STORAGE_ACCOUNT="stmcminecraftprod"
ENV_FILE="$(dirname "$0")/.env"

az login --identity --output none

kv_secret() {
  az keyvault secret show --vault-name "$KV_NAME" --name "$1" --query value -o tsv
}

VELOCITY_FORWARDING_SECRET=$(kv_secret "velocity-forwarding-secret")
RCON_PASSWORD=$(kv_secret "rcon-password")
C2E2_TAILSCALE_IP=$(kv_secret "c2e2-tailscale-ip")

cat > "$ENV_FILE" <<EOF
VELOCITY_FORWARDING_SECRET=${VELOCITY_FORWARDING_SECRET}
RCON_PASSWORD=${RCON_PASSWORD}
C2E2_TAILSCALE_IP=${C2E2_TAILSCALE_IP}
STORAGE_ACCOUNT=${STORAGE_ACCOUNT}
EOF

chmod 600 "$ENV_FILE"
echo "✓ .env written to ${ENV_FILE}"
