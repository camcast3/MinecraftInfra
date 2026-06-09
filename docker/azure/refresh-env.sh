#!/usr/bin/env bash
# docker/azure/refresh-env.sh
#
# Runs ON the Azure VM. Authenticates via the system-assigned Managed Identity,
# fetches secrets from Key Vault, and writes:
#   - docker/azure/.env              (env vars for docker compose)
#   - /data/minecraft/velocity/velocity.toml    (Velocity proxy config)
#   - /data/minecraft/velocity/forwarding.secret (Velocity modern forwarding secret)
#
# Called by the deploy workflow after `git pull`, before `docker compose up`.
# No credentials needed — the VM's MI has Key Vault Secrets User role.
#
# Usage (on the VM):
#   /opt/minecraft/docker/azure/refresh-env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KV_NAME="kv-minecraft-prod"
ENV_FILE="${SCRIPT_DIR}/.env"
VELOCITY_DIR="/data/minecraft/velocity"
TAILSCALE_DIR="/data/minecraft/tailscale"
# Tailnet hostname for the lobby sidecar — keep stable so tailnet ACLs and
# Prometheus scrape targets don't churn. Pinned here (not in Key Vault)
# because it's not a secret.
TS_HOSTNAME="lobby-azure"

az login --identity --output none

kv_secret() {
  az keyvault secret show --vault-name "$KV_NAME" --name "$1" --query value -o tsv
}

TS_AUTHKEY=$(kv_secret "tailscale-auth-key")
VELOCITY_FORWARDING_SECRET=$(kv_secret "velocity-forwarding-secret")
C2E2_TAILSCALE_IP=$(kv_secret "c2e2-tailscale-ip")

# ── .env for docker compose ───────────────────────────────────────────────────
cat > "$ENV_FILE" <<EOF
TS_AUTHKEY=${TS_AUTHKEY}
TS_HOSTNAME=${TS_HOSTNAME}
VELOCITY_FORWARDING_SECRET=${VELOCITY_FORWARDING_SECRET}
C2E2_TAILSCALE_IP=${C2E2_TAILSCALE_IP}
EOF
chmod 600 "$ENV_FILE"
echo "✓ .env written to ${ENV_FILE}"

# ── State directories ─────────────────────────────────────────────────────────
mkdir -p "$VELOCITY_DIR"
mkdir -p /data/minecraft/promtail
# Tailscale sidecar persists tailnet identity (node key, machine cert) here so
# it survives container recreation without re-using the auth key.
mkdir -p "$TAILSCALE_DIR"

# ── Velocity config ───────────────────────────────────────────────────────────
# Expand template variables into velocity.toml
export C2E2_TAILSCALE_IP VELOCITY_FORWARDING_SECRET
envsubst '${C2E2_TAILSCALE_IP} ${VELOCITY_FORWARDING_SECRET}' \
  < "${SCRIPT_DIR}/velocity/velocity.toml.tmpl" \
  > "${VELOCITY_DIR}/velocity.toml"
chmod 644 "${VELOCITY_DIR}/velocity.toml"
echo "✓ velocity.toml written to ${VELOCITY_DIR}/velocity.toml"

# forwarding.secret must contain only the secret string (no trailing newline)
printf '%s' "${VELOCITY_FORWARDING_SECRET}" > "${VELOCITY_DIR}/forwarding.secret"
chmod 600 "${VELOCITY_DIR}/forwarding.secret"
echo "✓ forwarding.secret written to ${VELOCITY_DIR}/forwarding.secret"
