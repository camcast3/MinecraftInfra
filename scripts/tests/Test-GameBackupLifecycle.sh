#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root="${repository_root}/build/game-backup-lifecycle"
backup_script="${repository_root}/infra/proxmox/game-node/backup/game-backup.sh"
recover_script="${repository_root}/infra/proxmox/game-node/backup/game-backup-recover.sh"

rm -rf "$test_root"
mkdir -p "$test_root/mockbin" "$test_root/mock-state"
trap 'rm -rf "$test_root"' EXIT

cat >"$test_root/mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
state=${MOCK_DOCKER_STATE:?}
command=${1:-}
shift || true
case "$command" in
  inspect)
    if [[ ${1:-} == "-f" || ${1:-} == "--format" ]]; then
      format=$2
      case "$format" in
        *RestartPolicy*) printf '%s\n' unless-stopped ;;
        *State.Running*) cat "$state/running" ;;
        *State.Health*) cat "$state/health" ;;
        *) exit 1 ;;
      esac
    fi
    ;;
  update) ;;
  stop) printf '%s\n' false >"$state/running" ;;
  start) printf '%s\n' true >"$state/running" ;;
  logs) printf '%s\n' "fixture docker logs" >&2 ;;
  *) echo "unexpected docker command: $command $*" >&2; exit 1 ;;
esac
EOF

cat >"$test_root/mockbin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$test_root/mockbin/rclone" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${MOCK_RCLONE_LOG:?}"
EOF

cat >"$test_root/mockbin/stat" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-} ${2:-}" in
  "-c %u") printf '%s\n' 0 ;;
  "-c %a") printf '%s\n' 600 ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF

chmod +x "$test_root/mockbin/"*

make_triplet() {
  local directory=$1
  local game=$2
  local timestamp=$3
  local age=$4
  local archive="${directory}/${game}-${timestamp}.tar.gz"
  mkdir -p "$directory"
  printf '%s\n' old >"$archive"
  printf '%064d  %s\n' 0 "$(basename "$archive")" >"${archive}.sha256"
  printf '{"status":"complete"}\n' >"${archive}.complete.json"
  touch -d "$age" "$archive" "${archive}.sha256" "${archive}.complete.json"
}

run_fixture() {
  local game=$1
  local stop_mode=$2
  local root="$test_root/$game"
  local data_root="$root/data-root"
  local backup_root="$data_root/backups"
  local nas_root="$root/nas"
  local config="$root/${game}.env"
  local rclone_config="$root/rclone.conf"
  local rclone_log="$root/rclone.log"
  local state="$test_root/mock-state/$game"
  local hook="$root/quiesce-hook"

  mkdir -p "$data_root/data" "$data_root/config" "$backup_root/local" \
    "$nas_root/$game" "$state"
  printf '%s-save\n' "$game" >"$data_root/data/save.fixture"
  printf '%s-config\n' "$game" >"$data_root/config/config.fixture"
  printf '%s\n' true >"$state/running"
  printf '%s\n' healthy >"$state/health"
  : >"$rclone_log"
  : >"$rclone_config"
  chmod 0600 "$rclone_config"

  cat >"$hook" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' false >"${MOCK_DOCKER_STATE:?}/running"
EOF
  chmod +x "$hook"

  make_triplet "$backup_root/local" "$game" 20000101T000000Z "20 days ago"
  make_triplet "$nas_root/$game" "$game" 20000101T000000Z "8 days ago"

  cat >"$config" <<EOF
DATA_ROOT=$data_root
BACKUP_ROOT=$backup_root
BACKUP_NAS_ROOT=$nas_root
AZURE_RCLONE_CONFIG=$rclone_config
AZURE_CONTAINER=${game}-backups
CONTAINER_NAME=${game}-server
BACKUP_SOURCE_NAMES=data:config
BACKUP_CONSISTENCY=fixture-cold-stop
BACKUP_STOP_MODE=$stop_mode
BACKUP_QUIESCE_HOOK=$hook
LOCAL_RETENTION_DAYS=14
NAS_RETENTION_DAYS=7
AZURE_RETENTION_DAYS=90
BACKUP_STOP_TIMEOUT_SECONDS=2
RESTART_HEALTH_TIMEOUT_SECONDS=2
EOF

  PATH="$test_root/mockbin:$PATH" \
    MOCK_DOCKER_STATE="$state" \
    MOCK_RCLONE_LOG="$rclone_log" \
    bash "$backup_script" --game "$game" --config "$config"

  [[ ! -e "$backup_root/local/${game}-20000101T000000Z.tar.gz" ]]
  [[ ! -e "$nas_root/$game/${game}-20000101T000000Z.tar.gz" ]]
  [[ ! -e "$backup_root/health/${game}.restart-required" ]]
  grep -Fq "delete azure:${game}-backups" "$rclone_log"
  grep -Fq -- "--min-age 90d" "$rclone_log"
  grep -Fq "destination=local status=success" \
    "$backup_root/health/events.log"
  grep -Fq "destination=nas status=success" "$backup_root/health/events.log"
  grep -Fq "destination=azure status=success" \
    "$backup_root/health/events.log"

  mapfile -t metadata < <(find "$backup_root/local" -maxdepth 1 \
    -name "${game}-*.tar.gz.complete.json")
  [[ ${#metadata[@]} -eq 1 ]]
  archive=${metadata[0]%.complete.json}
  checksum=$(sha256sum "$archive" | awk '{print $1}')
  grep -Fq "\"game\":\"${game}\"" "${archive}.complete.json"
  grep -Fq "\"sha256\":\"${checksum}\"" "${archive}.complete.json"
  grep -Fq "${checksum}" "${archive}.sha256"
  if find "$backup_root" -name '*.partial.*' -print -quit | grep -q .; then
    echo "Partial backup files remain for $game" >&2
    exit 1
  fi

  printf '%s\n' unless-stopped \
    >"$backup_root/health/${game}.restart-required"
  printf '%s\n' false >"$state/running"
  printf '%s\n' unhealthy >"$state/health"
  if PATH="$test_root/mockbin:$PATH" \
      MOCK_DOCKER_STATE="$state" \
      DATA_ROOT="$data_root" \
      CONTAINER_NAME="${game}-server" \
      RESTART_HEALTH_TIMEOUT_SECONDS=1 \
      bash "$recover_script" "$game"; then
    echo "Expected unhealthy restart recovery to fail for $game" >&2
    exit 1
  fi
  [[ -s "$backup_root/health/${game}.restart-required" ]]
  grep -Fq "destination=restart status=failure" \
    "$backup_root/health/events.log"

  printf '%s\n' healthy >"$state/health"
  PATH="$test_root/mockbin:$PATH" \
    MOCK_DOCKER_STATE="$state" \
    DATA_ROOT="$data_root" \
    CONTAINER_NAME="${game}-server" \
    RESTART_HEALTH_TIMEOUT_SECONDS=2 \
    bash "$recover_script" "$game"
  [[ ! -e "$backup_root/health/${game}.restart-required" ]]
  grep -Fq "destination=restart status=success" \
    "$backup_root/health/events.log"
}

run_fixture fixture-cold container-stop
run_fixture fixture-hook hook

echo "Generic backup lifecycle, retention, metadata, and recovery tests passed."
