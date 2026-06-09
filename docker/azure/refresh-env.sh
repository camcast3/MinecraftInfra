#!/usr/bin/env bash
# docker/azure/refresh-env.sh
#
# Runs ON the Azure VM. Authenticates via the system-assigned Managed Identity,
# fetches secrets from Key Vault, and writes:
#   - /opt/minecraft/secrets/ts_authkey                (tailscale auth key)
#   - /opt/minecraft/secrets/velocity_forwarding_secret (Velocity modern forwarding secret)
#   - /data/minecraft/velocity/velocity.toml           (Velocity proxy config — non-secret)
#
# Secrets live in /opt/minecraft/secrets (0700, root-owned) and are surfaced
# to containers via the docker compose `secrets:` directive (tailscale) or a
# single-file bind mount (velocity). No secret values are ever written to a
# .env file or any env var.
#
# Called by the deploy workflow after `git pull`, before `docker compose up`.
# No credentials needed — the VM's MI has Key Vault Secrets User role.
#
# To rotate any secret:
#   1) az keyvault secret set --vault-name kv-minecraft-prod --name <name> --value '...'
#   2) bash /opt/minecraft/docker/azure/refresh-env.sh
#   3) docker compose -f /opt/minecraft/docker/azure/docker-compose.yml up -d --force-recreate <service>
#
# Usage (on the VM):
#   /opt/minecraft/docker/azure/refresh-env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KV_NAME="kv-minecraft-prod"
SECRETS_DIR="/opt/minecraft/secrets"
VELOCITY_DIR="/data/minecraft/velocity"
TAILSCALE_DIR="/data/minecraft/tailscale"

# itzg/mc-proxy runs Velocity as UID 1000 (bungeecord) after a startup chown.
# Owning the forwarding-secret file as UID 1000 up front means itzg's
# `chown -R bungeecord:bungeecord /server` is a no-op for this file (which
# matters because it's a single-file bind mount — same-owner chown succeeds).
BUNGEECORD_UID=1000
BUNGEECORD_GID=1000

az login --identity --output none

kv_secret() {
  az keyvault secret show --vault-name "$KV_NAME" --name "$1" --query value -o tsv
}

TS_AUTHKEY=$(kv_secret "tailscale-auth-key")
VELOCITY_FORWARDING_SECRET=$(kv_secret "velocity-forwarding-secret")
C2E2_TAILSCALE_IP=$(kv_secret "c2e2-tailscale-ip")

# ── State directories ─────────────────────────────────────────────────────────
mkdir -p "$VELOCITY_DIR"
mkdir -p /data/minecraft/promtail
# Tailscale sidecar persists tailnet identity (node key, machine cert) here so
# it survives container recreation without re-using the auth key.
mkdir -p "$TAILSCALE_DIR"
# Secrets dir — 0700 root means nothing on the host except root and the docker
# daemon (also root) can traverse into it. Container processes only see the
# specific files mounted in by compose; they never see the directory.
install -d -m 0700 -o root -g root "$SECRETS_DIR"

# ── Secret files ──────────────────────────────────────────────────────────────
# Write atomically (tmp + chmod + chown + mv) so partial writes never leave a
# secret file with looser perms than intended.
write_secret() {
  local dest="$1" owner_uid="$2" owner_gid="$3" content="$4"
  local tmp
  tmp="$(mktemp -p "$SECRETS_DIR")"
  printf '%s' "$content" > "$tmp"
  chmod 0400 "$tmp"
  chown "${owner_uid}:${owner_gid}" "$tmp"
  mv -f "$tmp" "$dest"
}

# Tailscale container runs as root → root:root 0400 is readable.
write_secret "$SECRETS_DIR/ts_authkey" 0 0 "$TS_AUTHKEY"
echo "✓ ts_authkey written to ${SECRETS_DIR}/ts_authkey"

# Velocity container runs as bungeecord (UID 1000) → owner-readable 0400.
write_secret "$SECRETS_DIR/velocity_forwarding_secret" \
  "$BUNGEECORD_UID" "$BUNGEECORD_GID" "$VELOCITY_FORWARDING_SECRET"
echo "✓ velocity_forwarding_secret written to ${SECRETS_DIR}/velocity_forwarding_secret"

# ── Velocity config (non-secret) ──────────────────────────────────────────────
# velocity.toml only references the C2E2 backend IP — the forwarding secret is
# read by Velocity from /server/forwarding.secret (the single-file bind mount
# of velocity_forwarding_secret above), NOT from this file.
export C2E2_TAILSCALE_IP
envsubst '${C2E2_TAILSCALE_IP}' \
  < "${SCRIPT_DIR}/velocity/velocity.toml.tmpl" \
  > "${VELOCITY_DIR}/velocity.toml"
chmod 644 "${VELOCITY_DIR}/velocity.toml"
echo "✓ velocity.toml written to ${VELOCITY_DIR}/velocity.toml"

# ── Cleanup of legacy plaintext locations ─────────────────────────────────────
# Older revisions of this script wrote secrets to .env and /data/minecraft/.
# Remove them if they still exist so we don't leave plaintext lying around.
LEGACY_ENV="${SCRIPT_DIR}/.env"
LEGACY_FORWARDING_SECRET="${VELOCITY_DIR}/forwarding.secret"
for legacy in "$LEGACY_ENV" "$LEGACY_FORWARDING_SECRET"; do
  if [ -e "$legacy" ]; then
    rm -f "$legacy"
    echo "✓ removed legacy plaintext secret at ${legacy}"
  fi
done
