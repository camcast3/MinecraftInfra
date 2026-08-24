#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root="${repository_root}/build/game-backup-tests"
backup_script="${repository_root}/infra/proxmox/game-node/backup/game-backup.sh"
restore_script="${repository_root}/infra/proxmox/game-node/backup/game-restore.sh"
health_script="${repository_root}/infra/proxmox/game-node/backup/game-backup-health.sh"
recover_script="${repository_root}/infra/proxmox/game-node/backup/game-backup-recover.sh"
game=fixture-game

rm -rf "$test_root"
mkdir -p "$test_root/source/data/players" "$test_root/source/config" \
  "$test_root/archive" "$test_root/restores"
trap 'rm -rf "$test_root"' EXIT

printf 'fixture-save\n' >"$test_root/source/data/players/save.dat"
printf 'fixture-config\n' >"$test_root/source/config/server.json"
cat >"$test_root/fixture.env" <<EOF
DATA_ROOT=$test_root/source
BACKUP_SOURCE_NAMES=data:config
CONTAINER_NAME=fixture-game-server
BACKUP_CONSISTENCY=fixture-cold-stop
BACKUP_STOP_MODE=container-stop
EOF

plan=$(bash "$backup_script" --game "$game" \
  --config "$test_root/fixture.env" --dry-run)
grep -Fq 'container=fixture-game-server' <<<"$plan"
grep -Fq 'sources=data config' <<<"$plan"
grep -Fq 'consistency=fixture-cold-stop' <<<"$plan"
grep -Fq 'lifecycle=container-stop, confirmed stop, restart health' <<<"$plan"
grep -Fq 'retention=14d' <<<"$plan"
grep -Fq 'retention=7d' <<<"$plan"
grep -Fq 'tier=cold retention=90d' <<<"$plan"

health_root="$test_root/health-fixture"
stale_output=$(DATA_ROOT="$health_root" BACKUP_STALE_AFTER_SECONDS=60 \
  bash "$health_script" "$game")
grep -Fq "game=${game} destination=azure status=stale age_seconds=-1" \
  <<<"$stale_output"
mkdir -p "$health_root/backups/health"
date +%s >"$health_root/backups/health/${game}-azure.success"
healthy_output=$(DATA_ROOT="$health_root" BACKUP_STALE_AFTER_SECONDS=60 \
  bash "$health_script" "$game")
grep -Eq 'destination=azure status=healthy age_seconds=[0-9]+' \
  <<<"$healthy_output"
DATA_ROOT="$test_root/recovery-fixture" bash "$recover_script" "$game"

archive="$test_root/archive/${game}-fixture.tar.gz"
tar -czf "$archive" -C "$test_root/source" data config
checksum=$(sha256sum "$archive" | awk '{print $1}')
printf '%s  %s\n' "$checksum" "$(basename "$archive")" >"${archive}.sha256"
printf '{"schemaVersion":1,"status":"complete","game":"%s","archive":"%s","sha256":"%s"}\n' \
  "$game" "$(basename "$archive")" "$checksum" >"${archive}.complete.json"

bash "$restore_script" --game "$game" --archive "$archive" \
  --destination "$test_root/restores/dry-run" --dry-run |
  grep -Fq 'restore dry-run verified'
bash "$restore_script" --game "$game" --archive "$archive" \
  --destination "$test_root/restores/fixture"
cmp "$test_root/source/data/players/save.dat" \
  "$test_root/restores/fixture/data/players/save.dat"
cmp "$test_root/source/config/server.json" \
  "$test_root/restores/fixture/config/server.json"
grep -Fq "$checksum" \
  "$test_root/restores/fixture/RESTORE_VERIFIED_SHA256"

cp "$archive" "$test_root/archive/bad.tar.gz"
printf '%064d  bad.tar.gz\n' 0 >"$test_root/archive/bad.tar.gz.sha256"
cp "${archive}.complete.json" "$test_root/archive/bad.tar.gz.complete.json"
if bash "$restore_script" --game "$game" \
  --archive "$test_root/archive/bad.tar.gz" \
  --destination "$test_root/restores/bad" --dry-run 2>/dev/null; then
  echo "Expected checksum mismatch to fail" >&2
  exit 1
fi

wrong_game="$test_root/archive/wrong-game.tar.gz"
cp "$archive" "$wrong_game"
printf '%s  %s\n' "$checksum" "$(basename "$wrong_game")" \
  >"${wrong_game}.sha256"
printf '{"schemaVersion":1,"status":"complete","game":"other-game","archive":"%s","sha256":"%s"}\n' \
  "$(basename "$wrong_game")" "$checksum" >"${wrong_game}.complete.json"
if bash "$restore_script" --game "$game" --archive "$wrong_game" \
  --destination "$test_root/restores/wrong-game" --dry-run 2>/dev/null; then
  echo "Expected wrong-game metadata to fail" >&2
  exit 1
fi

incomplete="$test_root/archive/incomplete.tar.gz"
cp "$archive" "$incomplete"
printf '%s  %s\n' "$checksum" "$(basename "$incomplete")" \
  >"${incomplete}.sha256"
printf '{"schemaVersion":1,"status":"pending","game":"%s","archive":"%s","sha256":"%s"}\n' \
  "$game" "$(basename "$incomplete")" "$checksum" \
  >"${incomplete}.complete.json"
if bash "$restore_script" --game "$game" --archive "$incomplete" \
  --destination "$test_root/restores/incomplete" --dry-run 2>/dev/null; then
  echo "Expected incomplete metadata to fail" >&2
  exit 1
fi

if bash "$restore_script" --game "$game" --archive "$archive" \
  --destination "/data/${game}/restore-test" --dry-run 2>/dev/null; then
  echo "Expected live-path restore refusal" >&2
  exit 1
fi

echo "Game backup dry-run and isolated restore tests passed."
