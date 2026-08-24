#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

game=${1:-}
[[ "$game" =~ ^[a-z][a-z0-9-]*$ ]] || {
  echo "Usage: game-backup-recover GAME_SLUG" >&2
  exit 64
}

config="/etc/game-backup/${game}.env"
if [[ -r "$config" ]]; then
  # shellcheck disable=SC1090
  source "$config"
fi
DATA_ROOT=${DATA_ROOT:-"/data/${game}"}
BACKUP_ROOT=${BACKUP_ROOT:-"${DATA_ROOT}/backups"}
CONTAINER_NAME=${CONTAINER_NAME:-"${game}-server"}
RESTART_HEALTH_TIMEOUT_SECONDS=${RESTART_HEALTH_TIMEOUT_SECONDS:-480}
container=$CONTAINER_NAME
health_dir="${BACKUP_ROOT}/health"
state_file="${health_dir}/${game}.restart-required"
event_log="${health_dir}/events.log"

[[ -s "$state_file" ]] || exit 0
exec 9>"${BACKUP_ROOT}/.backup.lock"
flock -n 9 || exit 75

restart_policy=$(<"$state_file")
[[ "$restart_policy" == unless-stopped || "$restart_policy" == always ]] || {
  echo "Invalid saved restart policy for ${game}" >&2
  exit 78
}

docker update --restart="$restart_policy" "$container" >/dev/null
if [[ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]]; then
  docker start "$container" >/dev/null
fi

deadline=$((SECONDS + RESTART_HEALTH_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  state=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)
  if [[ "$state" == true && "$health" == healthy ]]; then
    rm -f "$state_file"
    sync -f "$health_dir"
    line="game_backup_result game=${game} destination=restart status=success"
    printf '%s\n' "$line" | tee -a "$event_log"
    exit 0
  fi
  [[ "$state" == true ]] || break
  sleep 5
done

line="game_backup_result game=${game} destination=restart status=failure exit_code=1"
printf '%s\n' "$line" | tee -a "$event_log"
docker logs --tail 100 "$container" >&2 || true
exit 1
