#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

game=${1:-}
[[ "$game" =~ ^[a-z][a-z0-9-]*$ ]] || {
  echo "Usage: game-backup-health GAME_SLUG" >&2
  exit 64
}

config="/etc/game-backup/${game}.env"
if [[ -r "$config" ]]; then
  # shellcheck disable=SC1090
  source "$config"
fi

DATA_ROOT=${DATA_ROOT:-"/data/${game}"}
BACKUP_ROOT=${BACKUP_ROOT:-"${DATA_ROOT}/backups"}
BACKUP_STALE_AFTER_SECONDS=${BACKUP_STALE_AFTER_SECONDS:-129600}
health_dir="${BACKUP_ROOT}/health"
event_log="${health_dir}/events.log"
mkdir -p "$health_dir"
touch "$event_log"

now=$(date +%s)
for destination in local nas azure; do
  marker="${health_dir}/${game}-${destination}.success"
  age=-1
  if [[ -s "$marker" ]]; then
    last=$(<"$marker")
    if [[ "$last" =~ ^[0-9]+$ ]]; then
      age=$((now - last))
    fi
  fi
  status=healthy
  if ((age < 0 || age > BACKUP_STALE_AFTER_SECONDS)); then
    status=stale
  fi
  line="game_backup_health game=${game} destination=${destination} status=${status} age_seconds=${age}"
  printf '%s\n' "$line" | tee -a "$event_log"
done
