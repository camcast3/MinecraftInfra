#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

usage() {
  echo "Usage: game-restore --game SLUG --archive PATH --destination PATH [--dry-run]" >&2
}

game=
archive=
destination=
dry_run=false
while (($#)); do
  case "$1" in
    --game) game=${2:-}; shift 2 ;;
    --archive) archive=${2:-}; shift 2 ;;
    --destination) destination=${2:-}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) usage; exit 64 ;;
  esac
done

[[ "$game" =~ ^[a-z][a-z0-9-]*$ ]] || {
  usage
  exit 64
}
[[ -n "$archive" && -n "$destination" ]] || {
  usage
  exit 64
}

archive=$(realpath -e "$archive")
destination=$(realpath -m "$destination")
case "$destination/" in
  /|/data/*)
    echo "Refusing to restore into a live or unsafe path: $destination" >&2
    exit 77
    ;;
esac
[[ ! -e "$destination" ]] || {
  echo "Restore destination already exists: $destination" >&2
  exit 73
}

checksum_file="${archive}.sha256"
metadata_file="${archive}.complete.json"
[[ -r "$checksum_file" && -r "$metadata_file" ]] || {
  echo "Archive requires sibling .sha256 and .complete.json files" >&2
  exit 66
}
grep -Fq '"status":"complete"' "$metadata_file"
grep -Fq "\"game\":\"${game}\"" "$metadata_file"
expected=$(awk 'NR == 1 {print $1}' "$checksum_file")
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid checksum file: $checksum_file" >&2
  exit 65
}
actual=$(sha256sum "$archive" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || {
  echo "Checksum mismatch for $archive" >&2
  exit 65
}
grep -Fq "\"archive\":\"$(basename "$archive")\"" "$metadata_file"
grep -Fq "\"sha256\":\"${actual}\"" "$metadata_file"

while IFS= read -r entry; do
  case "$entry" in
    /*|../*|*/../*|*/..)
      echo "Unsafe archive entry: $entry" >&2
      exit 65
      ;;
  esac
done < <(tar -tzf "$archive")

if [[ "$dry_run" == true ]]; then
  echo "restore dry-run verified game=${game} archive=${archive} destination=${destination}"
  exit 0
fi

if [[ $EUID -ne 0 && "$destination" == /data/* ]]; then
  echo "Root is required for restores under /data" >&2
  exit 77
fi

backup_root="/data/${game}/backups"
if [[ -d "$backup_root" ]]; then
  exec 9>"${backup_root}/.backup.lock"
  flock -n 9 || {
    echo "A ${game} backup or restore is already running" >&2
    exit 75
  }
fi

parent=$(dirname "$destination")
name=$(basename "$destination")
staging="${parent}/.${name}.restore.partial.$$"
mkdir -p "$parent"
[[ ! -e "$staging" ]]
mkdir "$staging"
cleanup() {
  local code=$?
  if ((code != 0)); then
    rm -rf -- "$staging"
  fi
  exit "$code"
}
trap cleanup EXIT
tar --extract --gzip --file "$archive" --directory "$staging" --numeric-owner --acls --xattrs
printf '%s\n' "$actual" >"${staging}/RESTORE_VERIFIED_SHA256"
mv "$staging" "$destination"
trap - EXIT
echo "Restored verified ${game} backup to isolated path: ${destination}"
