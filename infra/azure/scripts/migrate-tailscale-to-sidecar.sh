#!/usr/bin/env bash
# infra/azure/scripts/migrate-tailscale-to-sidecar.sh
#
# One-time migration of the live Azure VM from host-installed Tailscale to a
# Docker sidecar (services in docker/azure/docker-compose.yml).
#
# Sequenced to avoid the host port-25565 collision: the running velocity
# container has 25565 bound to the host, so the new tailscale container
# (which now publishes 25565 on behalf of the shared netns) can't start
# while the old velocity is still alive.
#
# Idempotent — safe to re-run. Detects whether host Tailscale and the sidecar
# are already in the target state and skips finished steps.
#
# How to run (from a workstation with az + Contributor on rg-minecraft-prod):
#   az vm run-command invoke \
#     --resource-group rg-minecraft-prod \
#     --name vm-minecraft-prod \
#     --command-id RunShellScript \
#     --scripts "@infra/azure/scripts/migrate-tailscale-to-sidecar.sh"
#
# After this completes successfully, the regular GitHub Actions deploy
# workflow handles all future updates with no special handling.

set -euo pipefail

REPO_DIR="/opt/minecraft"
COMPOSE_FILE="${REPO_DIR}/docker/azure/docker-compose.yml"
TS_STATE_DIR="/data/minecraft/tailscale"
ADMIN_USER="$(stat -c '%U' "${REPO_DIR}")"

log() { echo "[migrate-tailscale] $*"; }

# ── Step 0: Mark the worktree safe for git operations as root ────────────────
# --system writes to /etc/gitconfig and doesn't need $HOME (which isn't always
# set under `az vm run-command invoke`).
git config --system --add safe.directory "${REPO_DIR}"

# ── Step 1: Make /dev/net/tun present + persistent across reboots ────────────
if ! lsmod | grep -q '^tun'; then
  log "Loading tun module"
  modprobe tun
fi
if [ ! -f /etc/modules-load.d/tun.conf ]; then
  log "Persisting tun module load"
  echo tun > /etc/modules-load.d/tun.conf
fi

# ── Step 2: Pre-create state + secrets directories ───────────────────────────
mkdir -p "${TS_STATE_DIR}"
chown "${ADMIN_USER}:${ADMIN_USER}" "${TS_STATE_DIR}"
# Secrets dir (root-only). refresh-env.sh would also create it, but having it
# in place first lets us reason about ownership without relying on side effects.
install -d -m 0700 -o root -g root /opt/minecraft/secrets

# ── Step 3: Pull latest repo + refresh secret files (writes ts_authkey etc.) ─
cd "${REPO_DIR}"
git fetch origin
# Stay on whatever branch is currently checked out; the deploy workflow handles
# branch switching. This script just makes sure local files are current.
git reset --hard "@{u}"
log "Refreshing secret files from Key Vault"
bash docker/azure/refresh-env.sh

# ── Step 3b: Pre-flight — verify TS_AUTHKEY actually works ───────────────────
# A single-use Tailscale auth key that was already burned by the host install
# would let the migration tear down velocity and then fail at sidecar registration,
# leaving the site offline. Spin up a throwaway sidecar in userspace mode FIRST
# to test the key. If it can't register, abort BEFORE touching anything live.
TS_AUTHKEY_FILE="/opt/minecraft/secrets/ts_authkey"
if [ ! -s "$TS_AUTHKEY_FILE" ]; then
  log "ERROR: ${TS_AUTHKEY_FILE} missing/empty after refresh-env.sh — check Key Vault." >&2
  exit 1
fi
TS_AUTHKEY="$(cat "$TS_AUTHKEY_FILE")"

log "Pre-flight: spinning up throwaway sidecar (userspace mode, ephemeral) to verify TS_AUTHKEY"
PREFLIGHT_DIR=$(mktemp -d)
docker rm -f tailscale-preflight >/dev/null 2>&1 || true
# TS_EXTRA_ARGS=--ephemeral marks the node as ephemeral REGARDLESS of whether
# the auth key itself was created ephemeral. This guarantees the preflight node
# auto-deregisters from the tailnet admin UI when the container exits.
docker run -d \
  --name tailscale-preflight \
  --rm \
  -e TS_AUTHKEY="${TS_AUTHKEY}" \
  -e TS_HOSTNAME="lobby-azure-preflight" \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=true \
  -e TS_EXTRA_ARGS="--ephemeral" \
  -v "${PREFLIGHT_DIR}:/var/lib/tailscale" \
  tailscale/tailscale:v1.98.4 \
  >/dev/null

PREFLIGHT_OK=0
for i in $(seq 1 30); do
  if docker exec tailscale-preflight tailscale status >/dev/null 2>&1; then
    PREFLIGHT_OK=1
    break
  fi
  sleep 2
done

# Always tear down preflight, regardless of outcome. Ephemeral flag handles
# tailnet-side cleanup automatically.
docker rm -f tailscale-preflight >/dev/null 2>&1 || true
rm -rf "${PREFLIGHT_DIR}"

if [ "${PREFLIGHT_OK}" != "1" ]; then
  log "ERROR: The TS_AUTHKEY in Key Vault cannot register a new tailnet node." >&2
  log "       It was likely a single-use key already burned by the host install." >&2
  log "" >&2
  log "       Rotate it: generate a new REUSABLE + PRE-AUTHORIZED key at" >&2
  log "         https://login.tailscale.com/admin/settings/keys" >&2
  log "       Update the Key Vault secret:" >&2
  log "         az keyvault secret set --vault-name kv-minecraft-prod \\" >&2
  log "           --name tailscale-auth-key --value 'tskey-auth-...'" >&2
  log "       Then re-run this migration. No live state was changed." >&2
  exit 1
fi
log "Pre-flight passed: auth key is valid. Proceeding with migration."

# ── Step 4: Stop services that hold the host port 25565 ──────────────────────
# velocity and mc-monitor-exporter (current bridge-network ports). Tolerate
# either name being absent (re-runs after partial migration).
log "Stopping current velocity + mc-monitor-exporter to release port 25565"
docker compose -f "${COMPOSE_FILE}" stop velocity mc-monitor-exporter 2>/dev/null || true

# Belt-and-suspenders: remove the legacy bridge-networked containers entirely
# so compose doesn't try to reuse them with stale config.
docker rm -f velocity mc-monitor-exporter 2>/dev/null || true

# ── Step 5: Pull new images, bring up tailscale sidecar, wait for healthy ────
log "Pulling new images"
docker compose -f "${COMPOSE_FILE}" pull

log "Starting tailscale sidecar"
docker compose -f "${COMPOSE_FILE}" up -d tailscale

log "Waiting for tailscale sidecar to be healthy (up to 60s)"
TS_HEALTHY=0
for i in $(seq 1 30); do
  if docker exec tailscale-lobby tailscale status >/dev/null 2>&1; then
    TS_HEALTHY=1
    log "tailscale sidecar is up:"
    docker exec tailscale-lobby tailscale ip -4 || true
    docker exec tailscale-lobby tailscale status --self=true | head -3 || true
    break
  fi
  sleep 2
done
if [ "${TS_HEALTHY}" != "1" ]; then
  log "ERROR: tailscale sidecar did not become healthy within 60s. Aborting." >&2
  log "       'docker logs tailscale-lobby' for details." >&2
  exit 1
fi

# Verify the sidecar can reach the C2E2 backend over the tailnet. Without this,
# we'd happily rip out host tailscaled while Velocity has no working route to
# the backend (e.g. if tailnet ACLs don't permit the new lobby-azure node).
# Fetch C2E2 IP straight from Key Vault — refresh-env.sh no longer writes it
# to .env (which no longer exists).
C2E2_IP="$(az keyvault secret show --vault-name kv-minecraft-prod \
  --name c2e2-tailscale-ip --query value -o tsv 2>/dev/null || true)"
if [ -n "${C2E2_IP}" ]; then
  log "Pinging C2E2 backend at ${C2E2_IP} from the sidecar netns"
  # tailscale flags use Go's flag package; use --flag=value form to avoid
  # any ambiguity with positional args (the IP).
  if ! docker exec tailscale-lobby tailscale ping --c=3 --timeout=5s "${C2E2_IP}" 2>&1 | tail -5; then
    log "WARNING: tailscale ping to ${C2E2_IP} failed. Check tailnet ACLs/auth-key tags." >&2
    log "         Proceeding anyway — Velocity may still work if ACLs allow TCP but not ICMP." >&2
  fi
fi

# ── Step 6: Bring up the rest of the stack ───────────────────────────────────
log "Starting full stack (will recreate velocity in tailscale netns)"
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

# ── Step 7: Verify port bindings and stack health ────────────────────────────
log "Listening sockets on 25565:"
ss -tlnp 2>/dev/null | grep ':25565' || log "  (no listeners — investigate!)"

log "Container status:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# ── Step 8: Disable host Tailscale ───────────────────────────────────────────
if systemctl is-enabled --quiet tailscaled 2>/dev/null; then
  log "Disabling host tailscaled"
  systemctl disable --now tailscaled || true
fi

# ── Step 9: Purge host Tailscale package ─────────────────────────────────────
if dpkg -l tailscale >/dev/null 2>&1; then
  log "Purging host tailscale package"
  apt-get remove --purge -y tailscale
  apt-get autoremove -y
fi

# ── Step 10: Tidy the now-obsolete UFW rule for tailscale0 interface ─────────
# ufw status often lists v4 + v6 rules separately; iterate by numbered index
# in reverse order until none reference tailscale0. Each delete shifts numbers,
# hence the loop.
while ufw status numbered 2>/dev/null | grep -q 'tailscale0'; do
  RULE_NUM=$(ufw status numbered 2>/dev/null | grep 'tailscale0' | head -1 | sed -E 's/^\[ *([0-9]+)\].*/\1/')
  if [ -z "${RULE_NUM}" ]; then break; fi
  log "Removing obsolete UFW rule #${RULE_NUM} (tailscale0)"
  yes | ufw delete "${RULE_NUM}" >/dev/null 2>&1 || break
done

# ── Step 11: Free disk used by old dangling docker images ────────────────────
log "Pruning dangling docker images"
docker image prune -f

log "Migration complete."
log "Verify:"
log "  - Public connection still works: mcstatus mc.negativezone.cc"
log "  - Sidecar tailnet IP visible at: tailscale --tnet web (admin UI)"
log "  - Velocity logs show real player IPs (not 172.x): docker logs velocity"
