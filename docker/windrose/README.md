# Windrose Portainer stack

This stack runs Kraken Express's official amd64 native Linux image. It does
not install SteamCMD or Wine. The game shares a network namespace with its own
Tailscale sidecar and listens for direct connections on TCP and UDP 7777.
Nothing publishes 7777 or the unverified 7778 directly on the Proxmox host.

The pinned release was inspected without starting the game: its payload is an
x86-64 ELF linked against Linux libraries, `/usr/bin/wine` and `wine64` are
absent, and the image metadata exposes only TCP/UDP 7777. The upstream image
still launches through nested shell scripts, so this stack execs the native
binary directly.

## Portainer setup

Create a Git stack whose Compose path is
`docker/windrose/docker-compose.yml`. Set these values in Portainer's stack
environment UI:

<!-- markdownlint-disable MD013 -->

| Name | Required | Purpose |
| --- | ---: | --- |
| `WINDROSE_TS_AUTHKEY` | yes | Short-lived, preauthorized Tailscale auth key |
| `WINDROSE_TS_HOSTNAME` | no | Per-stack tailnet name; defaults to `windrose-game` |
| `WINDROSE_SERVER_DESCRIPTION_JSON` | yes for bootstrap | Complete JSON file, including any password |
| `WINDROSE_RESEED_SERVER_DESCRIPTION` | no | Set to `true` for one controlled replacement |

<!-- markdownlint-enable MD013 -->

`WINDROSE_SERVER_DESCRIPTION_JSON` must contain the complete generated server
description, with `"UseDirectConnection": true` and
`"DirectConnectionServerPort": 7777`. Keep its generated
`PersistentServerId` and `WorldIslandId`. The launcher writes it atomically
only when the persistent file is absent, unless reseeding is explicitly
enabled. After a reseed succeeds, set `WINDROSE_RESEED_SERVER_DESCRIPTION`
back to `false`.

The official image ships `R5/ServerDescription.json` outside its declared
`R5/Saved` volume. A direct single-file bind is unsafe when the host file does
not exist because Docker can create a directory at that path. This stack
instead mounts `/data/windrose/config`, stores the file there, and replaces
the image's empty file with a symlink before execing the native server.

## Persistence and permissions

The game-node cloud-init creates these uid-1000-owned directories:

- `/data/windrose/data` → `R5/Saved`
- `/data/windrose/config` → persistent `ServerDescription.json`
- `/data/windrose/tailscale` → sidecar identity and state
- `/data/windrose/backups` → local archives, completion metadata, and health
  signals from the host systemd backup service
- `/data/windrose/monitoring/alloy` → Alloy positions and component state

Do not run two server containers against the same data. Edit or replace the
server description only while `windrose` is stopped.

## Networking and health

The health check requires the native server process plus TCP and UDP listeners
on 7777. The Tailscale sidecar has an independent health check. Do not open a
home-router port or add 7778 unless official documentation later requires it.
Any public ingress is a separate reviewed change.

## Shutdown, backup, and updates

The launcher `exec`s the native Unreal server directly, avoiding the official
image's nested shell process chain. Compose sends `SIGTERM` and allows two
minutes before forced termination. A production stop/save still needs
observation during the first controlled deployment.

The host `game-backup@windrose.timer` disables the restart policy, stops the
container, confirms both the container and native server process are gone,
then archives `data` and `config`. It therefore never copies active
`RocksDB_v2`. After writing checksum and completion metadata it restores the
restart policy and requires a healthy server before publishing to the NAS and
Azure Cold tiers. Alloy ships backup failure and stale-success events.

Use the isolated restore procedure in
[`../../ops/backups.md`](../../ops/backups.md). It refuses live paths.

Renovate updates the explicit image tag and digest. Review upstream release
notes, take a completed cold backup, redeploy through Portainer, and require a
healthy server before allowing players to reconnect.
