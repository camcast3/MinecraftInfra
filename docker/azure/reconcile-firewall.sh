#!/usr/bin/env bash

set -euo pipefail

if ! command -v ufw >/dev/null 2>&1; then
  echo "ERROR: ufw is not installed." >&2
  exit 1
fi

# customData is immutable after VM creation, so every deploy replaces the live
# host policy with the repository's exact player-facing surface.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 25565/tcp comment 'Minecraft players'
ufw allow 8211/udp comment 'Palworld players'
ufw allow 7777/tcp comment 'Windrose players TCP'
ufw allow 7777/udp comment 'Windrose players UDP'
ufw --force enable

ufw status verbose
