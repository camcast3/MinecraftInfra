#!/usr/bin/env bash
# docker/azure/refresh-env.sh
#
# Runs ON the Azure VM. Authenticates via the system-assigned Managed Identity,
# fetches secrets from Key Vault, and writes:
#   - /opt/minecraft/secrets/ts_authkey              (tailscale auth key OR placeholder)
#   - /data/minecraft/velocity/forwarding.secret     (Velocity modern forwarding secret)
#   - /data/minecraft/velocity/velocity.toml         (Velocity proxy config — non-secret)
#
# ts_authkey is consumed via docker compose `secrets:`. forwarding.secret is
# written into the velocity data dir directly (NOT to /opt/minecraft/secrets/)
# because the data-dir bind mount shadows any single-file bind layered on top
# of /server — see docker-compose.yml volumes for the postmortem.
# No secret values are ever written to a .env file or env var.
#
# ── Tailscale auth-key handling (security model) ──────────────────────────────
# The Tailscale sidecar uses a SINGLE-USE auth key. Once it has registered, the
# tailnet control plane burns the key and the node identity (private node key,
# machine cert) is persisted to /data/minecraft/tailscale/tailscaled.state.
# Future container restarts use the cached state — they don't touch the auth
# key file at all (TS_AUTH_ONCE=true in docker-compose.yml enforces this).
#
# Once the state file exists, this script writes a DEAD PLACEHOLDER to
# /opt/minecraft/secrets/ts_authkey instead of the live Key Vault value. So:
#   - A compromised tailscale container that reads /run/secrets/ts_authkey
#     gets a placeholder string — useless to register a new tailnet node.
#   - The live Key Vault value never sits on the VM disk past the first
#     registration (cloud-init re-runs this script after the sidecar boots
#     to immediately overwrite the live key with the placeholder).
#
# To rotate the Tailscale auth key (which IS a re-registration, since state is
# the actual node identity):
#   1) az keyvault secret set --vault-name kv-minecraft-prod --name tailscale-auth-key --value 'tskey-auth-...'
#   2) docker compose -f /opt/minecraft/docker/azure/docker-compose.yml stop tailscale
#   3) rm -rf /data/minecraft/tailscale/*                # wipe node identity
#   4) bash /opt/minecraft/docker/azure/refresh-env.sh   # state absent → writes live key
#   5) docker compose -f /opt/minecraft/docker/azure/docker-compose.yml up -d --force-recreate tailscale
#   6) bash /opt/minecraft/docker/azure/refresh-env.sh   # state now present → overwrites with placeholder
#
# To rotate the Velocity forwarding secret. CRITICAL — coordinated across BOTH
# hosts. The secret is a shared HMAC key between Velocity (Azure) and the
# Craft-to-Exile-2 backend (Proxmox); if they disagree, the backend rejects
# the proxy's modern-forwarding handshake and players see "Unable to connect"
# until both sides agree again. Order:
#   1) Generate one new value (used by both hosts):
#        NEW=$(openssl rand -hex 32)
#   2) On the operator workstation (Azure):
#        az keyvault secret set --vault-name kv-minecraft-prod \
#          --name velocity-forwarding-secret --value "$NEW"
#   3) In Portainer UI (Proxmox stack):
#        Set VELOCITY_FORWARDING_SECRET = $NEW on the C2E2 stack.
#        Click "Update the stack" — Portainer recreates c2e2 with the new value
#        injected at startup via PATCH_DEFINITIONS.
#   4) On the Azure VM (via `az vm run-command invoke`):
#        bash /opt/minecraft/docker/azure/refresh-env.sh
#      The script detects the change and restarts velocity automatically.
# Steps 3 and 4 should happen within the same ~minute window to minimise the
# player-visible outage. If you can only do one at a time, do Proxmox first —
# Velocity will fail-closed (reject backend connections) and players see a
# clean disconnect rather than a half-broken session.
#
# Called by the deploy workflow after `git pull`, before `docker compose up`.
# No credentials needed — the VM's MI has Key Vault Secrets User role.
#
# Usage (on the VM):
#   /opt/minecraft/docker/azure/refresh-env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KV_NAME="kv-minecraft-prod"
SECRETS_DIR="/opt/minecraft/secrets"
VELOCITY_DIR="/data/minecraft/velocity"
TAILSCALE_DIR="/data/minecraft/tailscale"

# The Tailscale sidecar runs as root in its user namespace (see compose file
# for the capability-set rationale — stock image, no file caps; Compose can't
# set ambient caps). Auth-key file is therefore owned 0:0 0400 (root).
TAILSCALE_UID=0
TAILSCALE_GID=0

# itzg/mc-proxy runs Velocity as UID 1000 (bungeecord) after a startup chown.
# Owning the forwarding-secret file as UID 1000 up front means itzg's
# `chown -R bungeecord:bungeecord /server` is a no-op for this file (which
# matters because it's a single-file bind mount — same-owner chown succeeds).
BUNGEECORD_UID=1000
BUNGEECORD_GID=1000

# Dead placeholder written in place of the live Tailscale auth key after the
# sidecar has registered. The leading `tskey-auth-` keeps the static format
# check in migrate-tailscale-to-sidecar.sh happy (so the placeholder looks
# like a real key shape), but the actual value will never be accepted by
# Tailscale's control plane — registration would fail immediately if anything
# tried to use it.
TAILSCALE_DEAD_PLACEHOLDER="tskey-auth-DEAD-REGISTERED-NODE-WIPE-STATE-TO-ROTATE"

az login --identity --output none

kv_secret() {
  az keyvault secret show --vault-name "$KV_NAME" --name "$1" --query value -o tsv
}

VELOCITY_FORWARDING_SECRET=$(kv_secret "velocity-forwarding-secret")
C2E2_TAILSCALE_IP=$(kv_secret "c2e2-tailscale-ip")

# ── State directories ─────────────────────────────────────────────────────────
mkdir -p "$VELOCITY_DIR"
mkdir -p /data/minecraft/promtail
# Tailscale state dir is created + chowned by cloud-init (vm.bicep) to
# root:root, mode 0700. Don't recreate it here — that would clobber the perms
# on subsequent runs. We DO want to fail loud if it's gone.
if [ ! -d "$TAILSCALE_DIR" ]; then
  echo "ERROR: ${TAILSCALE_DIR} missing — cloud-init should have created it." >&2
  exit 1
fi
# Secrets dir — 0700 root means nothing on the host except root and the docker
# daemon (also root) can traverse into it. Container processes only see the
# specific files mounted in by compose; they never see the directory.
install -d -m 0700 -o root -g root "$SECRETS_DIR"

# ── Secret files ──────────────────────────────────────────────────────────────
# Atomic secret write. mktemp uses the destination's parent dir so the final
# mv is a same-filesystem rename and never fails with EXDEV — lets the helper
# write to either /opt/minecraft/secrets/ or /data/minecraft/velocity/.
write_secret() {
  local dest="$1" owner_uid="$2" owner_gid="$3" content="$4"
  local dest_dir
  dest_dir=$(dirname "$dest")
  local tmp
  tmp="$(mktemp -p "$dest_dir")"
  printf '%s' "$content" > "$tmp"
  chmod 0400 "$tmp"
  chown "${owner_uid}:${owner_gid}" "$tmp"
  mv -f "$tmp" "$dest"
}

# ── Tailscale auth key (state-aware) ─────────────────────────────────────────
# tailscaled writes its long-lived node identity to <statedir>/tailscaled.state
# on first successful registration. If that file exists and is non-empty, the
# node is already registered — the auth key value in KV is no longer needed
# for normal operation, so we write a dead placeholder to disk instead of
# leaving the live key sitting in /opt/minecraft/secrets/ts_authkey where a
# compromised container could exfiltrate it.
if [ -s "${TAILSCALE_DIR}/tailscaled.state" ]; then
  write_secret "$SECRETS_DIR/ts_authkey" \
    "$TAILSCALE_UID" "$TAILSCALE_GID" "$TAILSCALE_DEAD_PLACEHOLDER"
  echo "✓ ts_authkey: dead placeholder (sidecar already registered; live key not written to disk)"
else
  TS_AUTHKEY=$(kv_secret "tailscale-auth-key")
  if [ -z "$TS_AUTHKEY" ]; then
    echo "ERROR: tailscale-auth-key in Key Vault is empty." >&2
    exit 1
  fi
  write_secret "$SECRETS_DIR/ts_authkey" \
    "$TAILSCALE_UID" "$TAILSCALE_GID" "$TS_AUTHKEY"
  echo "✓ ts_authkey: live key written (state file absent — first registration)"
fi

# Restarts (forwarding.secret + velocity.toml) are coalesced into one
# `docker compose restart velocity` at the bottom of this script.
VELOCITY_RESTART_REASONS=()

# ── Velocity forwarding secret ────────────────────────────────────────────────
# Written into the velocity data dir directly — see docker-compose.yml volumes
# for why a single-file bind onto /server/forwarding.secret doesn't work.
# Mode 0400 UID 1000 so itzg's chown -R inside /server is a same-owner no-op.
FORWARDING_SECRET_DEST="${VELOCITY_DIR}/forwarding.secret"
NEW_FORWARDING_SECRET_SHA=$(printf '%s' "$VELOCITY_FORWARDING_SECRET" | sha256sum | cut -d' ' -f1)
OLD_FORWARDING_SECRET_SHA=""
if [ -f "$FORWARDING_SECRET_DEST" ]; then
  OLD_FORWARDING_SECRET_SHA=$(sha256sum < "$FORWARDING_SECRET_DEST" | cut -d' ' -f1)
fi
if [ "$NEW_FORWARDING_SECRET_SHA" = "$OLD_FORWARDING_SECRET_SHA" ]; then
  echo "✓ velocity forwarding.secret unchanged"
else
  write_secret "$FORWARDING_SECRET_DEST" \
    "$BUNGEECORD_UID" "$BUNGEECORD_GID" "$VELOCITY_FORWARDING_SECRET"
  echo "✓ velocity forwarding.secret written to ${FORWARDING_SECRET_DEST}"
  VELOCITY_RESTART_REASONS+=("forwarding.secret changed")
fi

# ── Velocity config (non-secret) ──────────────────────────────────────────────
# velocity.toml only references the C2E2 backend IP — the forwarding secret is
# read by Velocity from /server/forwarding.secret (written above), NOT from
# this file.
#
# velocity.toml is bind-mounted via /data/minecraft/velocity:/server, so
# Velocity reads its content ONLY at process start. `docker compose up -d`
# after a git pull won't recreate the container when only the template
# changes, so we diff against the on-disk file and queue a restart below.
# Keeps the fallback MOTD (bumped on every modpack publish via
# publish-prism-pack.ps1) in sync with what players see during a backend outage.
export C2E2_TAILSCALE_IP
NEW_VELOCITY_TOML=$(mktemp -p "$VELOCITY_DIR" .velocity.toml.new.XXXXXX)
envsubst '${C2E2_TAILSCALE_IP}' \
  < "${SCRIPT_DIR}/velocity/velocity.toml.tmpl" \
  > "$NEW_VELOCITY_TOML"
chmod 644 "$NEW_VELOCITY_TOML"

if [ -f "${VELOCITY_DIR}/velocity.toml" ] && cmp -s "$NEW_VELOCITY_TOML" "${VELOCITY_DIR}/velocity.toml"; then
  rm -f "$NEW_VELOCITY_TOML"
  echo "✓ velocity.toml unchanged"
else
  mv -f "$NEW_VELOCITY_TOML" "${VELOCITY_DIR}/velocity.toml"
  echo "✓ velocity.toml written to ${VELOCITY_DIR}/velocity.toml"
  VELOCITY_RESTART_REASONS+=("velocity.toml changed")
fi

# ── Velocity restart (single, if any input changed above) ────────────────────
# Skip if velocity isn't running yet — the next `docker compose up -d` will
# create it with the fresh config.
if [ "${#VELOCITY_RESTART_REASONS[@]}" -gt 0 ]; then
  COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
  if docker compose -f "$COMPOSE_FILE" ps --status=running --services 2>/dev/null | grep -qx 'velocity'; then
    docker compose -f "$COMPOSE_FILE" restart velocity
    echo "✓ velocity restarted (${VELOCITY_RESTART_REASONS[*]})"
  else
    echo "✓ velocity not running — next docker compose up will use new config (${VELOCITY_RESTART_REASONS[*]})"
  fi
fi

# ── Cleanup of legacy locations ───────────────────────────────────────────────
# Stale plaintext locations from earlier revisions:
#   - .env in the compose dir
#   - /opt/minecraft/secrets/velocity_forwarding_secret (former source-of-truth
#     for the shadowed single-file bind mount — see PR #154)
LEGACY_ENV="${SCRIPT_DIR}/.env"
LEGACY_FORWARDING_SECRET_FILE="${SECRETS_DIR}/velocity_forwarding_secret"
for legacy in "$LEGACY_ENV" "$LEGACY_FORWARDING_SECRET_FILE"; do
  if [ -e "$legacy" ]; then
    rm -f "$legacy"
    echo "✓ removed legacy secret file at ${legacy}"
  fi
done
