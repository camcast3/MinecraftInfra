#!/bin/sh
set -eu

mkdir -p /state
printf '%s\n' "${RELEASE:?RELEASE is required}" > /state/current-release

trap 'exit 0' TERM INT
while :; do
  if [ -e /state/crash-once ]; then
    rm -f /state/crash-once
    exit 42
  fi
  sleep 1
done
