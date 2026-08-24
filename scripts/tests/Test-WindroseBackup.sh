#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root="${repository_root}/build/windrose-backup-tests"
backup_script="${repository_root}/infra/proxmox/game-node/backup/game-backup.sh"
hook="${repository_root}/infra/proxmox/game-node/backup/windrose"

rm -rf "$test_root"
mkdir -p "$test_root/mockbin" "$test_root/proc"
trap 'rm -rf "$test_root"' EXIT

plan=$(DATA_ROOT=/data/windrose \
  CONTAINER_NAME=windrose-server \
  BACKUP_SOURCE_NAMES=data:config \
  BACKUP_CONSISTENCY=confirmed-cold-stop \
  BACKUP_STOP_MODE=hook \
  AZURE_CONTAINER=windrose-backups \
  bash "$backup_script" --game windrose \
    --config "$test_root/missing.env" --dry-run)
grep -Fq 'container=windrose-server' <<<"$plan"
grep -Fq 'sources=data config' <<<"$plan"
grep -Fq 'consistency=confirmed-cold-stop' <<<"$plan"
grep -Fq 'lifecycle=hook, confirmed stop, restart health' <<<"$plan"
grep -Fq 'azure=azure:windrose-backups tier=cold retention=90d' <<<"$plan"

cat >"$test_root/mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  stop)
    printf '%s\n' "$*" >"${MOCK_DOCKER_LOG:?}"
    ;;
  inspect)
    case "${3:-}" in
      *Running*) printf '%s\n' false ;;
      *Pid*) printf '%s\n' 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF

chmod +x "$test_root/mockbin/"*

MOCK_DOCKER_LOG="$test_root/docker.log" \
  PROC_ROOT="$test_root/proc" \
  PATH="$test_root/mockbin:$PATH" \
  bash "$hook" windrose-server 120
grep -Fq 'stop --time 120 windrose-server' "$test_root/docker.log"

mkdir -p "$test_root/proc/123"
printf '%s\0' '/home/ue_user/app/R5/Binaries/Linux/WindroseServer-Linux-Shipping' \
  >"$test_root/proc/123/cmdline"
if output=$(MOCK_DOCKER_LOG="$test_root/docker.log" \
    PROC_ROOT="$test_root/proc" \
    PATH="$test_root/mockbin:$PATH" \
    bash "$hook" windrose-server 120 2>&1); then
  echo 'Expected active Windrose process guard to fail' >&2
  exit 1
fi
grep -Fq 'Refusing to copy active Windrose RocksDB_v2 data' <<<"$output"

echo 'Windrose cold-backup hook and framework dry-run passed.'
