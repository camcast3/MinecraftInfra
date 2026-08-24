#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root="${repository_root}/build/game-backup-tests"
backup_script="${repository_root}/platform/proxmox/game-node/backup/game-backup.sh"
restore_script="${repository_root}/platform/proxmox/game-node/backup/game-restore.sh"
health_script="${repository_root}/platform/proxmox/game-node/backup/game-backup-health.sh"
recover_script="${repository_root}/platform/proxmox/game-node/backup/game-backup-recover.sh"

rm -rf "$test_root"
mkdir -p "$test_root/source/data/Players" "$test_root/source/config" "$test_root/archive" "$test_root/restores"
trap 'rm -rf "$test_root"' EXIT

printf 'palworld-save\n' >"$test_root/source/data/Players/save.sav"
printf 'windrose-config\n' >"$test_root/source/config/ServerDescription.json"
printf 'windrose-rocksdb-fixture\n' >"$test_root/source/data/RocksDB_v2.fixture"

palworld_plan=$(bash "$backup_script" --game palworld --config "$test_root/missing.env" --dry-run)
grep -Fq 'private REST announce/save/shutdown' <<<"$palworld_plan"
grep -Fq 'retention=14d' <<<"$palworld_plan"
grep -Fq 'retention=7d' <<<"$palworld_plan"
grep -Fq 'tier=cold retention=90d' <<<"$palworld_plan"

windrose_plan=$(bash "$backup_script" --game windrose --config "$test_root/missing.env" --dry-run)
grep -Fq 'RocksDB_v2 is never copied active' <<<"$windrose_plan"

health_root="$test_root/health-fixture"
stale_output=$(DATA_ROOT="$health_root" BACKUP_STALE_AFTER_SECONDS=60 \
  bash "$health_script" palworld)
grep -Fq 'destination=azure status=stale age_seconds=-1' <<<"$stale_output"
mkdir -p "$health_root/backups/health"
date +%s >"$health_root/backups/health/palworld-azure.success"
healthy_output=$(DATA_ROOT="$health_root" BACKUP_STALE_AFTER_SECONDS=60 \
  bash "$health_script" palworld)
grep -Eq 'destination=azure status=healthy age_seconds=[0-9]+' <<<"$healthy_output"
DATA_ROOT="$test_root/recovery-fixture" bash "$recover_script" palworld

archive="$test_root/archive/palworld-fixture.tar.gz"
tar -czf "$archive" -C "$test_root/source" data
checksum=$(sha256sum "$archive" | awk '{print $1}')
printf '%s  %s\n' "$checksum" "$(basename "$archive")" >"${archive}.sha256"
printf '{"schemaVersion":1,"status":"complete","game":"palworld","archive":"%s","sha256":"%s"}\n' \
  "$(basename "$archive")" "$checksum" >"${archive}.complete.json"

bash "$restore_script" --game palworld --archive "$archive" \
  --destination "$test_root/restores/palworld-dry" --dry-run | grep -Fq 'restore dry-run verified'
bash "$restore_script" --game palworld --archive "$archive" \
  --destination "$test_root/restores/palworld"
cmp "$test_root/source/data/Players/save.sav" \
  "$test_root/restores/palworld/data/Players/save.sav"
grep -Fq "$checksum" "$test_root/restores/palworld/RESTORE_VERIFIED_SHA256"

windrose_archive="$test_root/archive/windrose-fixture.tar.gz"
tar -czf "$windrose_archive" -C "$test_root/source" data config
windrose_checksum=$(sha256sum "$windrose_archive" | awk '{print $1}')
printf '%s  %s\n' "$windrose_checksum" "$(basename "$windrose_archive")" \
  >"${windrose_archive}.sha256"
printf '{"schemaVersion":1,"status":"complete","game":"windrose","archive":"%s","sha256":"%s"}\n' \
  "$(basename "$windrose_archive")" "$windrose_checksum" \
  >"${windrose_archive}.complete.json"
bash "$restore_script" --game windrose --archive "$windrose_archive" \
  --destination "$test_root/restores/windrose"
cmp "$test_root/source/data/RocksDB_v2.fixture" \
  "$test_root/restores/windrose/data/RocksDB_v2.fixture"
cmp "$test_root/source/config/ServerDescription.json" \
  "$test_root/restores/windrose/config/ServerDescription.json"

cp "$archive" "$test_root/archive/bad.tar.gz"
printf '%064d  bad.tar.gz\n' 0 >"$test_root/archive/bad.tar.gz.sha256"
cp "${archive}.complete.json" "$test_root/archive/bad.tar.gz.complete.json"
if bash "$restore_script" --game palworld --archive "$test_root/archive/bad.tar.gz" \
  --destination "$test_root/restores/bad" --dry-run 2>/dev/null; then
  echo "Expected checksum mismatch to fail" >&2
  exit 1
fi

wrong_game="$test_root/archive/wrong-game.tar.gz"
cp "$archive" "$wrong_game"
printf '%s  %s\n' "$checksum" "$(basename "$wrong_game")" >"${wrong_game}.sha256"
printf '{"schemaVersion":1,"status":"complete","game":"windrose","archive":"%s","sha256":"%s"}\n' \
  "$(basename "$wrong_game")" "$checksum" >"${wrong_game}.complete.json"
if bash "$restore_script" --game palworld --archive "$wrong_game" \
  --destination "$test_root/restores/wrong-game" --dry-run 2>/dev/null; then
  echo "Expected wrong-game metadata to fail" >&2
  exit 1
fi

incomplete="$test_root/archive/incomplete.tar.gz"
cp "$archive" "$incomplete"
printf '%s  %s\n' "$checksum" "$(basename "$incomplete")" >"${incomplete}.sha256"
printf '{"schemaVersion":1,"status":"pending","game":"palworld","archive":"%s","sha256":"%s"}\n' \
  "$(basename "$incomplete")" "$checksum" >"${incomplete}.complete.json"
if bash "$restore_script" --game palworld --archive "$incomplete" \
  --destination "$test_root/restores/incomplete" --dry-run 2>/dev/null; then
  echo "Expected incomplete metadata to fail" >&2
  exit 1
fi

if bash "$restore_script" --game palworld --archive "$archive" \
  --destination /data/palworld/data/restore-test --dry-run 2>/dev/null; then
  echo "Expected live-path restore refusal" >&2
  exit 1
fi

echo "All game backup dry-run and isolated restore tests passed."
