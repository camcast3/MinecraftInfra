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
# Single-use auth key model:
#   The sidecar uses a single-use Tailscale auth key. Once registered, the
#   node identity persists at /data/minecraft/tailscale/tailscaled.state and
#   the key is burned. Refresh-env.sh detects state-exists and writes a dead
#   placeholder to /opt/minecraft/secrets/ts_authkey from that point onward
#   so a compromised container cannot exfiltrate a usable key.
#
#   This script registers the node in a throwaway USERSPACE-mode container
#   that uses the REAL persistent state dir — so first-registration happens
#   BEFORE we touch the live velocity container. If registration fails (bad
#   or already-burned key), zero state changes; velocity keeps running.
#
# How to run (from a workstation with az + Contributor on rg-minecraft-prod):
#   az vm run-command invoke \
#     --resource-group rg-minecraft-prod \
#     --name vm-minecraft-prod \
#     --command-id RunShellScript \
#     --scripts "@infra/azure/scripts/migrate-tailscale-to-sidecar.sh"
#
# To test against a non-main branch, set MIGRATE_REF in the script body before
# running (you can edit the assignment below, or just override via something
# like `MIGRATE_REF=cacarlt/branch-name bash …`).
#
# After this completes successfully, the regular GitHub Actions deploy
# workflow handles all future updates with no special handling.

set -euo pipefail

REPO_DIR="/opt/minecraft"
COMPOSE_FILE="${REPO_DIR}/docker/azure/docker-compose.yml"
TS_STATE_DIR="/data/minecraft/tailscale"
SECRETS_DIR="/opt/minecraft/secrets"
TS_AUTHKEY_FILE="${SECRETS_DIR}/ts_authkey"
TAILSCALE_UID=10001
TAILSCALE_GID=10001
TAILSCALE_IMAGE="tailscale/tailscale:v1.98.4@sha256:6146dfe83373a68b57379f8a748676971f036c418d8bc8f4ed3b6ba3f7cc04dc"

# Allow override for testing on a non-main branch:
#   MIGRATE_REF=cacarlt/some-branch az vm run-command invoke ...
# Default is `main` because we only run this in production after the PR merges.
TARGET_REF="${MIGRATE_REF:-main}"

log() { echo "[migrate-tailscale] $*"; }

# ── Step -1: Authenticate via VM Managed Identity ────────────────────────────
# refresh-env.sh re-authenticates later in this script, but we also call
# `az keyvault secret show` directly (Step 5) and want a logged-in session
# already in place. `az login --identity` is idempotent if already logged in.
export HOME=/root
az login --identity --output none

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

# ── Step 1b: tailscale-svc user/group + udev rule for /dev/net/tun ───────────
# The sidecar runs as non-root UID/GID 10001. /dev/net/tun is 0600 root:root by
# default; we group-scope it to tailscale-svc with mode 0660 so the container
# can open the device. The actual privilege gate is still CAP_NET_ADMIN, which
# only the tailscale container has — file perms here are only the DAC check.
if ! getent group tailscale-svc >/dev/null; then
  log "Creating tailscale-svc group (gid ${TAILSCALE_GID})"
  groupadd -g "${TAILSCALE_GID}" tailscale-svc
fi
if ! getent passwd tailscale-svc >/dev/null; then
  log "Creating tailscale-svc user (uid ${TAILSCALE_UID})"
  useradd -u "${TAILSCALE_UID}" -g "${TAILSCALE_GID}" -M -r -s /usr/sbin/nologin tailscale-svc
fi
if [ ! -f /etc/udev/rules.d/99-tun.rules ]; then
  log "Installing udev rule for /dev/net/tun (group tailscale-svc, 0660)"
  cat > /etc/udev/rules.d/99-tun.rules <<'EOF'
KERNEL=="tun", GROUP="tailscale-svc", MODE="0660"
EOF
fi
# Apply to the live device immediately (udev rule kicks in on next module
# reload / reboot; we want the migration to work right now).
chgrp tailscale-svc /dev/net/tun
chmod 0660 /dev/net/tun

# ── Step 2: Pre-create state + secrets directories ───────────────────────────
# State dir is owned by tailscale-svc (10001:10001) and mode 0700 — it holds
# the tailscaled node identity which is itself the high-value secret. Only
# root and tailscale-svc can read it. NOT chowned to ADMIN_USER (intentional).
mkdir -p "${TS_STATE_DIR}"
chown "${TAILSCALE_UID}:${TAILSCALE_GID}" "${TS_STATE_DIR}"
chmod 0700 "${TS_STATE_DIR}"
# Secrets dir (root-only). refresh-env.sh would also create it, but having it
# in place first lets us reason about ownership without relying on side effects.
install -d -m 0700 -o root -g root "${SECRETS_DIR}"

# ── Step 3: Pull latest repo + refresh secret files (writes ts_authkey etc.) ─
cd "${REPO_DIR}"
# Explicit target ref instead of `@{u}` — the latter requires upstream tracking
# on whatever branch happens to be checked out, which is fine on a cloud-init
# clone (HEAD on main with origin/main tracking) but breaks on detached HEAD or
# unusual checkouts. Being explicit also makes it obvious what version of the
# stack we're rolling forward to.
log "Fetching and resetting to origin/${TARGET_REF}"
git fetch origin "${TARGET_REF}"
git checkout "${TARGET_REF}"
git reset --hard "origin/${TARGET_REF}"
log "Refreshing secret files from Key Vault"
bash docker/azure/refresh-env.sh

# ── Step 3b: Pre-flight — static checks on the auth key file ─────────────────
# refresh-env.sh either wrote a live key (state empty) or a dead placeholder
# (state already exists from a prior partial migration). On a fresh migration
# we expect a live key — if we got a placeholder, refresh-env.sh decided the
# node was already registered, so we should skip straight to step 4.
if [ ! -s "${TS_AUTHKEY_FILE}" ]; then
  log "ERROR: ${TS_AUTHKEY_FILE} missing/empty after refresh-env.sh — check Key Vault." >&2
  exit 1
fi
if ! grep -qE '^tskey-auth-' "${TS_AUTHKEY_FILE}"; then
  log "ERROR: ${TS_AUTHKEY_FILE} doesn't look like a tailscale auth key (no tskey-auth- prefix)." >&2
  exit 1
fi
if grep -q '^tskey-auth-DEAD-REGISTERED-NODE' "${TS_AUTHKEY_FILE}"; then
  log "Auth-key file is the dead placeholder → tailscaled.state already exists."
  log "Skipping pre-flight registration; the main sidecar will use cached state."
  ALREADY_REGISTERED=1
else
  ALREADY_REGISTERED=0
fi

# ── Step 3c: Pre-flight registration into the REAL state dir ─────────────────
# Runs ONLY when we still have a live key on disk (the normal first-migration
# case). The throwaway container uses the persistent state dir so registration
# survives its teardown; the main sidecar will then start with TS_AUTH_ONCE=true
# and not consume any key. If registration fails, zero live-state change —
# velocity keeps serving players.
#
# Userspace mode (TS_USERSPACE=true) avoids needing /dev/net/tun for the test.
# Runs as UID 10001 (matches main sidecar) so the state files inherit the
# right ownership. Auth key is passed via file mount, NEVER as an env var,
# so it doesn't leak via `docker inspect` / /proc/<pid>/environ.
if [ "${ALREADY_REGISTERED}" = "0" ]; then
  log "Pre-flight: registering tailnet node into ${TS_STATE_DIR} (userspace mode, no live state change)"
  docker rm -f tailscale-preflight >/dev/null 2>&1 || true
  docker run -d \
    --name tailscale-preflight \
    --rm \
    --user "${TAILSCALE_UID}:${TAILSCALE_GID}" \
    -e TS_AUTHKEY="file:/run/secrets/ts_authkey" \
    -e TS_HOSTNAME="proxy-azure" \
    -e TS_STATE_DIR=/var/lib/tailscale \
    -e TS_USERSPACE=true \
    -e TS_AUTH_ONCE=true \
    -e TS_ACCEPT_DNS=false \
    -e TS_SOCKET=/tmp/tailscaled.sock \
    -v "${TS_STATE_DIR}:/var/lib/tailscale" \
    -v "${TS_AUTHKEY_FILE}:/run/secrets/ts_authkey:ro" \
    "${TAILSCALE_IMAGE}" \
    >/dev/null

  PREFLIGHT_OK=0
  for i in $(seq 1 30); do
    # `tailscale ip -4` is exit 0 only after the node has been issued a
    # tailnet IPv4 (i.e. registered + online). `tailscale status` returns 0
    # even when the node is logged-out, which would race the placeholder
    # swap below.
    if docker exec tailscale-preflight tailscale --socket=/tmp/tailscaled.sock ip -4 >/dev/null 2>&1; then
      PREFLIGHT_OK=1
      break
    fi
    sleep 2
  done

  if [ "${PREFLIGHT_OK}" != "1" ]; then
    log "ERROR: Pre-flight registration failed within 60s. Last container logs:" >&2
    docker logs tailscale-preflight 2>&1 | tail -20 >&2 || true
    docker rm -f tailscale-preflight >/dev/null 2>&1 || true
    log "" >&2
    log "Likely cause: TS_AUTHKEY in Key Vault is already burned (single-use keys" >&2
    log "can only register one node). Rotate it: generate a new SINGLE-USE +" >&2
    log "PRE-AUTHORIZED + NON-EPHEMERAL key at" >&2
    log "  https://login.tailscale.com/admin/settings/keys" >&2
    log "then:" >&2
    log "  az keyvault secret set --vault-name kv-minecraft-prod \\" >&2
    log "    --name tailscale-auth-key --value 'tskey-auth-...'" >&2
    log "and re-run this migration. No live state was changed." >&2
    exit 1
  fi
  log "Pre-flight registration succeeded. State persisted to ${TS_STATE_DIR}."
  # Tear the pre-flight container down; the state files in TS_STATE_DIR remain.
  docker rm -f tailscale-preflight >/dev/null 2>&1 || true

  # Now that tailscaled.state exists, re-run refresh-env.sh so it overwrites
  # the live key on disk with the dead placeholder. From this point forward the
  # only thing a compromised container can leak is a useless string.
  log "Overwriting live auth key on disk with dead placeholder"
  bash docker/azure/refresh-env.sh
fi

# ── Step 4: Pre-pull new images BEFORE breaking the running site ─────────────
# `docker compose pull` only downloads layers; it doesn't recreate containers.
# Pulling here while velocity is still serving traffic shrinks the public
# outage window to "stop velocity → tailscale becomes healthy" instead of
# "stop velocity → pull → tailscale becomes healthy". If a registry hiccup
# stretches the pull into minutes, players keep playing.
log "Pre-pulling new images (velocity still serving traffic)"
docker compose -f "${COMPOSE_FILE}" pull

# ── Step 5: Snapshot tailscale state before bringing up the main sidecar ─────
# Cheap insurance against compose somehow corrupting the freshly-registered
# state files (the tailscaled.state we just wrote is the irreplaceable node
# identity). State is < 10 KB total, so the snapshot is essentially free.
if [ -s "${TS_STATE_DIR}/tailscaled.state" ]; then
  BAK="${TS_STATE_DIR}.bak.$(date +%s)"
  log "Snapshotting ${TS_STATE_DIR} to ${BAK}"
  cp -a "${TS_STATE_DIR}" "${BAK}"
fi

# ── Step 6: Stop services that hold the host port 25565 ──────────────────────
# velocity and mc-monitor-exporter (current bridge-network ports). Tolerate
# either name being absent (re-runs after partial migration).
log "Stopping current velocity + mc-monitor-exporter to release port 25565"
docker compose -f "${COMPOSE_FILE}" stop velocity mc-monitor-exporter 2>/dev/null || true

# Belt-and-suspenders: remove the legacy bridge-networked containers entirely
# so compose doesn't try to reuse them with stale config.
docker rm -f velocity mc-monitor-exporter 2>/dev/null || true

# ── Step 7: Bring up tailscale sidecar (image already local), wait healthy ───
log "Starting tailscale sidecar"
docker compose -f "${COMPOSE_FILE}" up -d tailscale

log "Waiting for tailscale sidecar to be healthy (up to 60s)"
TS_HEALTHY=0
for i in $(seq 1 30); do
  # `tailscale ip -4` — same rationale as the pre-flight loop above. We need
  # the node to actually have a tailnet IP before we start velocity, otherwise
  # velocity will try to dial the C2E2 backend and fail.
  if docker exec tailscale-lobby tailscale --socket=/tmp/tailscaled.sock ip -4 >/dev/null 2>&1; then
    TS_HEALTHY=1
    log "tailscale sidecar is up:"
    docker exec tailscale-lobby tailscale --socket=/tmp/tailscaled.sock ip -4 || true
    docker exec tailscale-lobby tailscale --socket=/tmp/tailscaled.sock status --self=true | head -3 || true
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
# the backend (e.g. if tailnet ACLs don't permit the new proxy-azure node).
# Fetch C2E2 IP straight from Key Vault — refresh-env.sh no longer writes it
# to .env (which no longer exists).
C2E2_IP="$(az keyvault secret show --vault-name kv-minecraft-prod \
  --name c2e2-tailscale-ip --query value -o tsv 2>/dev/null || true)"
if [ -n "${C2E2_IP}" ]; then
  log "Pinging C2E2 backend at ${C2E2_IP} from the sidecar netns"
  # tailscale flags use Go's flag package; use --flag=value form to avoid
  # any ambiguity with positional args (the IP).
  if ! docker exec tailscale-lobby tailscale --socket=/tmp/tailscaled.sock ping --c=3 --timeout=5s "${C2E2_IP}" 2>&1 | tail -5; then
    log "WARNING: tailscale ping to ${C2E2_IP} failed. Check tailnet ACLs/auth-key tags." >&2
    log "         Proceeding anyway — Velocity may still work if ACLs allow TCP but not ICMP." >&2
  fi
fi

# ── Step 8: Bring up the rest of the stack ───────────────────────────────────
log "Starting full stack (will recreate velocity in tailscale netns)"
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

# ── Step 9: Verify port bindings and stack health ────────────────────────────
log "Listening sockets on 25565:"
ss -tlnp 2>/dev/null | grep ':25565' || log "  (no listeners — investigate!)"

log "Container status:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# ── Step 10: Disable host Tailscale ──────────────────────────────────────────
if systemctl is-enabled --quiet tailscaled 2>/dev/null; then
  log "Disabling host tailscaled"
  systemctl disable --now tailscaled || true
fi

# ── Step 11: Purge host Tailscale package ────────────────────────────────────
if dpkg -l tailscale >/dev/null 2>&1; then
  log "Purging host tailscale package"
  apt-get remove --purge -y tailscale
  apt-get autoremove -y
fi

# ── Step 12: Tidy the now-obsolete UFW rules (tailscale0 + UDP 25565) ────────
# ufw status often lists v4 + v6 rules separately; iterate by numbered index
# in reverse order until none reference tailscale0. Each delete shifts numbers,
# hence the loop.
while ufw status numbered 2>/dev/null | grep -q 'tailscale0'; do
  RULE_NUM=$(ufw status numbered 2>/dev/null | grep 'tailscale0' | head -1 | sed -E 's/^\[ *([0-9]+)\].*/\1/')
  if [ -z "${RULE_NUM}" ]; then break; fi
  log "Removing obsolete UFW rule #${RULE_NUM} (tailscale0)"
  yes | ufw delete "${RULE_NUM}" >/dev/null 2>&1 || break
done
# Java Edition is TCP only; older cloud-init revisions allowed UDP 25565.
while ufw status numbered 2>/dev/null | grep -E '25565/udp' >/dev/null; do
  RULE_NUM=$(ufw status numbered 2>/dev/null | grep -E '25565/udp' | head -1 | sed -E 's/^\[ *([0-9]+)\].*/\1/')
  if [ -z "${RULE_NUM}" ]; then break; fi
  log "Removing obsolete UFW rule #${RULE_NUM} (25565/udp)"
  yes | ufw delete "${RULE_NUM}" >/dev/null 2>&1 || break
done

# ── Step 13: Free disk used by old dangling docker images ────────────────────
log "Pruning dangling docker images"
docker image prune -f

log "Migration complete."
log "Verify:"
log "  - Public connection still works: mcstatus mc.negativezone.cc"
log "  - Sidecar tailnet IP visible at: tailscale --tnet web (admin UI)"
log "  - Velocity logs show real player IPs (not 172.x): docker logs velocity"
log "If anything looks wrong, the pre-pull state-dir snapshot is at:"
log "  ls -la /data/minecraft/tailscale.bak.* 2>/dev/null"
