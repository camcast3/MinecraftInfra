#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

usage() {
  echo "Usage: game-backup --game palworld|windrose [--config PATH] [--dry-run]" >&2
}

game=
config=
dry_run=false
while (($#)); do
  case "$1" in
    --game)
      game=${2:-}
      shift 2
      ;;
    --config)
      config=${2:-}
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

case "$game" in
  palworld)
    container=palworld-server
    source_names=(data)
    consistency=palworld-rest-graceful-stop
    ;;
  windrose)
    container=windrose-server
    source_names=(data config)
    consistency=confirmed-cold-stop
    ;;
  *)
    usage
    exit 64
    ;;
esac

config=${config:-"/etc/game-backup/${game}.env"}
if [[ -r "$config" ]]; then
  # shellcheck disable=SC1090
  source "$config"
elif [[ "$dry_run" != true ]]; then
  echo "Backup configuration is not readable: $config" >&2
  exit 78
fi

DATA_ROOT=${DATA_ROOT:-"/data/${game}"}
BACKUP_ROOT=${BACKUP_ROOT:-"${DATA_ROOT}/backups"}
BACKUP_NAS_ROOT=${BACKUP_NAS_ROOT:-/mnt/nas-backups}
AZURE_RCLONE_REMOTE=${AZURE_RCLONE_REMOTE:-azure}
AZURE_CONTAINER=${AZURE_CONTAINER:-"${game}-backups"}
AZURE_RCLONE_CONFIG=${AZURE_RCLONE_CONFIG:-/etc/game-backup/rclone.conf}
AZURE_ACCESS_TIER=${AZURE_ACCESS_TIER:-cold}
LOCAL_RETENTION_DAYS=${LOCAL_RETENTION_DAYS:-14}
NAS_RETENTION_DAYS=${NAS_RETENTION_DAYS:-7}
AZURE_RETENTION_DAYS=${AZURE_RETENTION_DAYS:-90}
PALWORLD_SHUTDOWN_WAIT_SECONDS=${PALWORLD_SHUTDOWN_WAIT_SECONDS:-60}
WINDROSE_STOP_TIMEOUT_SECONDS=${WINDROSE_STOP_TIMEOUT_SECONDS:-120}
RESTART_HEALTH_TIMEOUT_SECONDS=${RESTART_HEALTH_TIMEOUT_SECONDS:-480}

for value in \
  "$LOCAL_RETENTION_DAYS" \
  "$NAS_RETENTION_DAYS" \
  "$AZURE_RETENTION_DAYS" \
  "$PALWORLD_SHUTDOWN_WAIT_SECONDS" \
  "$WINDROSE_STOP_TIMEOUT_SECONDS" \
  "$RESTART_HEALTH_TIMEOUT_SECONDS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "Retention and timeout values must be positive integers" >&2
    exit 78
  }
done

if [[ "$dry_run" == true ]]; then
  cat <<EOF
game=${game}
container=${container}
sources=${source_names[*]}
consistency=${consistency}
local=${BACKUP_ROOT}/local retention=${LOCAL_RETENTION_DAYS}d
nas=${BACKUP_NAS_ROOT}/${game} retention=${NAS_RETENTION_DAYS}d
azure=${AZURE_RCLONE_REMOTE}:${AZURE_CONTAINER} tier=${AZURE_ACCESS_TIER} retention=${AZURE_RETENTION_DAYS}d
lifecycle=$([[ "$game" == palworld ]] && echo "private REST announce/save/shutdown, confirmed stop, restart health" || echo "confirmed cold stop, restart health; RocksDB_v2 is never copied active")
dry-run: no API, Docker, filesystem, NAS, or Azure changes were made
EOF
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "game-backup must run as root" >&2
  exit 77
fi

for command_name in docker flock mountpoint pgrep rclone sha256sum sync tar; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is missing: $command_name" >&2
    exit 69
  }
done

local_dir="${BACKUP_ROOT}/local"
health_dir="${BACKUP_ROOT}/health"
work_dir="${BACKUP_ROOT}/work"
event_log="${health_dir}/events.log"
restart_state="${health_dir}/${game}.restart-required"
mkdir -p "$local_dir" "$health_dir" "$work_dir"
chmod 0750 "$BACKUP_ROOT" "$local_dir" "$health_dir" "$work_dir"
touch "$event_log"
chmod 0640 "$event_log"

exec 9>"${BACKUP_ROOT}/.backup.lock"
if ! flock -n 9; then
  echo "Another ${game} backup or restore operation holds ${BACKUP_ROOT}/.backup.lock" >&2
  exit 75
fi

log_event() {
  local line=$1
  printf '%s\n' "$line" | tee -a "$event_log"
}

record_result() {
  local destination=$1
  local status=$2
  local exit_code=${3:-}
  local line="game_backup_result game=${game} destination=${destination} status=${status}"
  if [[ -n "$exit_code" ]]; then
    line+=" exit_code=${exit_code}"
  fi
  log_event "$line"
}

record_success_marker() {
  local destination=$1
  local marker="${health_dir}/${game}-${destination}.success"
  local temporary="${marker}.new.$$"
  date +%s >"$temporary"
  sync -f "$temporary"
  mv -f "$temporary" "$marker"
  sync -f "$health_dir"
}

mark_restart_required() {
  local temporary="${restart_state}.new.$$"
  printf '%s\n' "$original_restart_policy" >"$temporary"
  sync -f "$temporary"
  mv -f "$temporary" "$restart_state"
  sync -f "$health_dir"
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$container")" == true ]]
}

wait_for_stop() {
  local timeout=$1
  local deadline=$((SECONDS + timeout))
  while container_running; do
    if ((SECONDS >= deadline)); then
      echo "${container} did not stop within ${timeout} seconds" >&2
      return 1
    fi
    sleep 2
  done
}

wait_for_health() {
  local deadline=$((SECONDS + RESTART_HEALTH_TIMEOUT_SECONDS))
  local state health
  while ((SECONDS < deadline)); do
    state=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)
    if [[ "$state" == true && "$health" == healthy ]]; then
      return 0
    fi
    if [[ "$state" != true && -n "$state" ]]; then
      echo "${container} stopped while waiting for health" >&2
      docker logs --tail 100 "$container" >&2 || true
      return 1
    fi
    sleep 5
  done
  echo "${container} did not become healthy within ${RESTART_HEALTH_TIMEOUT_SECONDS} seconds" >&2
  docker logs --tail 100 "$container" >&2 || true
  return 1
}

palworld_post() {
  local endpoint=$1
  local payload=${2:-}
  docker exec "$container" /bin/sh -ceu '
    endpoint=$1
    payload=$2
    if [ -n "$payload" ]; then
      curl --fail --silent --show-error --max-time 15 --request POST \
        --user "admin:${PALWORLD_ADMIN_PASSWORD:?}" \
        --header "Content-Type: application/json" --data "$payload" \
        "http://127.0.0.1:8212/v1/api/${endpoint}" >/dev/null
    else
      curl --fail --silent --show-error --max-time 15 --request POST \
        --user "admin:${PALWORLD_ADMIN_PASSWORD:?}" \
        "http://127.0.0.1:8212/v1/api/${endpoint}" >/dev/null
    fi
  ' backup-api "$endpoint" "$payload"
}

assert_cold() {
  if container_running; then
    echo "Refusing to archive while ${container} is running" >&2
    return 1
  fi
  if [[ "$game" == windrose ]] && pgrep -f '[W]indroseServer-Linux-Shipping' >/dev/null; then
    echo "Refusing to copy active Windrose RocksDB_v2 data" >&2
    return 1
  fi
}

initially_running=false
restart_required=false
original_restart_policy=
current_destination=local
failure_recorded=false

resume_game() {
  if [[ "$initially_running" != true ]]; then
    restart_required=false
    return 0
  fi
  docker update --restart="$original_restart_policy" "$container" >/dev/null || return
  if ! container_running; then
    docker start "$container" >/dev/null || return
  fi
  wait_for_health || return
  rm -f "$restart_state"
  sync -f "$health_dir"
  restart_required=false
}

cleanup() {
  local code=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ "$restart_required" == true ]]; then
    if ! resume_game; then
      log_event "game_backup_restart game=${game} status=failure container=${container}"
      code=1
    fi
  fi
  if ((code != 0)) && [[ "$failure_recorded" != true ]]; then
    record_result "$current_destination" failure "$code"
  fi
  find "$work_dir" -maxdepth 1 -type f -name '*.partial.*' -delete 2>/dev/null || true
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

if ! docker inspect "$container" >/dev/null 2>&1; then
  echo "Container does not exist: $container" >&2
  exit 69
fi
if container_running; then
  initially_running=true
  original_restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container")
  [[ "$original_restart_policy" == unless-stopped || "$original_restart_policy" == always ]] || {
    echo "Unexpected restart policy for ${container}: ${original_restart_policy}" >&2
    exit 78
  }
elif [[ "$game" == palworld ]]; then
  echo "Palworld must be healthy so its private REST save/shutdown workflow can run" >&2
  exit 69
fi

if [[ "$game" == palworld ]]; then
  wait_for_health
  palworld_post announce "{\"message\":\"Scheduled backup begins in ${PALWORLD_SHUTDOWN_WAIT_SECONDS} seconds\"}"
  palworld_post save
  restart_required=true
  mark_restart_required
  docker update --restart=no "$container" >/dev/null
  palworld_post shutdown "{\"waittime\":${PALWORLD_SHUTDOWN_WAIT_SECONDS},\"message\":\"Scheduled backup in progress\"}"
  wait_for_stop "$((PALWORLD_SHUTDOWN_WAIT_SECONDS + 45))"
elif [[ "$initially_running" == true ]]; then
  restart_required=true
  mark_restart_required
  docker update --restart=no "$container" >/dev/null
  docker stop --time "$WINDROSE_STOP_TIMEOUT_SECONDS" "$container" >/dev/null
  wait_for_stop 15
fi
assert_cold

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
archive_name="${game}-${timestamp}.tar.gz"
checksum_name="${archive_name}.sha256"
metadata_name="${archive_name}.complete.json"
archive_work="${work_dir}/${archive_name}.partial.$$"
checksum_work="${work_dir}/${checksum_name}.partial.$$"
metadata_work="${work_dir}/${metadata_name}.partial.$$"

tar_arguments=(
  --create
  --gzip
  --file "$archive_work"
  --one-file-system
  --numeric-owner
  --acls
  --xattrs
  --directory "$DATA_ROOT"
)
tar "${tar_arguments[@]}" "${source_names[@]}"
archive_sha=$(sha256sum "$archive_work" | awk '{print $1}')
printf '%s  %s\n' "$archive_sha" "$archive_name" >"$checksum_work"
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"schemaVersion":1,"status":"complete","game":"%s","createdUtc":"%s","archive":"%s","sha256":"%s","consistency":"%s"}\n' \
  "$game" "$created_utc" "$archive_name" "$archive_sha" "$consistency" >"$metadata_work"

sync -f "$archive_work"
sync -f "$checksum_work"
sync -f "$metadata_work"
mv "$archive_work" "${local_dir}/${archive_name}"
mv "$checksum_work" "${local_dir}/${checksum_name}"
mv "$metadata_work" "${local_dir}/${metadata_name}"
sync -f "$local_dir"

resume_game

prune_filesystem() {
  local directory=$1
  local days=$2
  local marker base
  while IFS= read -r -d '' marker; do
    base=${marker%.complete.json}
    rm -f -- "$base" "${base}.sha256" "$marker"
  done < <(find "$directory" -maxdepth 1 -type f -name "${game}-*.tar.gz.complete.json" -mmin "+$((days * 1440))" -print0)
  find "$directory" -maxdepth 1 -type f -name '*.partial.*' -mmin +2880 -delete
}

prune_filesystem "$local_dir" "$LOCAL_RETENTION_DAYS"
record_success_marker local
record_result local success

copy_filesystem_tier() {
  local destination=$1
  local destination_archive="${destination}/${archive_name}"
  mkdir -p "$destination"
  cp "${local_dir}/${archive_name}" "${destination_archive}.partial.$$"
  cp "${local_dir}/${checksum_name}" "${destination}/${checksum_name}.partial.$$"
  cp "${local_dir}/${metadata_name}" "${destination}/${metadata_name}.partial.$$"
  sync -f "${destination_archive}.partial.$$"
  sync -f "${destination}/${checksum_name}.partial.$$"
  sync -f "${destination}/${metadata_name}.partial.$$"
  mv "${destination_archive}.partial.$$" "$destination_archive"
  mv "${destination}/${checksum_name}.partial.$$" "${destination}/${checksum_name}"
  [[ "$(sha256sum "$destination_archive" | awk '{print $1}')" == "$archive_sha" ]]
  mv "${destination}/${metadata_name}.partial.$$" "${destination}/${metadata_name}"
  sync -f "$destination"
}

publish_nas() (
  set -Eeuo pipefail
  mountpoint -q "$BACKUP_NAS_ROOT"
  local destination="${BACKUP_NAS_ROOT}/${game}"
  copy_filesystem_tier "$destination"
  prune_filesystem "$destination" "$NAS_RETENTION_DAYS"
)

publish_azure() (
  set -Eeuo pipefail
  [[ -r "$AZURE_RCLONE_CONFIG" ]]
  [[ "$(stat -c %u "$AZURE_RCLONE_CONFIG")" == 0 ]]
  config_mode=$(stat -c %a "$AZURE_RCLONE_CONFIG")
  (( (8#$config_mode & 077) == 0 ))
  local destination="${AZURE_RCLONE_REMOTE}:${AZURE_CONTAINER}"
  local common_args=(--config "$AZURE_RCLONE_CONFIG" --azureblob-access-tier "$AZURE_ACCESS_TIER")
  rclone copyto "${local_dir}/${archive_name}" "${destination}/${archive_name}" "${common_args[@]}"
  rclone copyto "${local_dir}/${checksum_name}" "${destination}/${checksum_name}" "${common_args[@]}"
  rclone copyto "${local_dir}/${metadata_name}" "${destination}/${metadata_name}" "${common_args[@]}"
  rclone delete "$destination" --config "$AZURE_RCLONE_CONFIG" \
    --min-age "${AZURE_RETENTION_DAYS}d" \
    --include "${game}-*.tar.gz" \
    --include "${game}-*.tar.gz.sha256" \
    --include "${game}-*.tar.gz.complete.json"
)

destination_failed=false
current_destination=nas
set +e
publish_nas
nas_code=$?
set -e
if ((nas_code == 0)); then
  record_success_marker nas
  record_result nas success
else
  record_result nas failure "$nas_code"
  destination_failed=true
fi

current_destination=azure
set +e
publish_azure
azure_code=$?
set -e
if ((azure_code == 0)); then
  record_success_marker azure
  record_result azure success
else
  record_result azure failure "$azure_code"
  destination_failed=true
fi

if [[ "$destination_failed" == true ]]; then
  failure_recorded=true
  exit 1
fi
