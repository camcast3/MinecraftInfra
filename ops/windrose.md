# Windrose operations

The production source is
[`docker/windrose/docker-compose.yml`](../docker/windrose/docker-compose.yml).
Portainer deploys it to the dedicated Proxmox VM using the official
digest-pinned native Linux image.

## Network boundary

- Do not forward a home-router port to the Windrose VM.
- The Compose stack publishes no host ports.
- Direct player traffic uses TCP and UDP 7777 in the stack Tailscale network
  namespace.
- Port 7778 is not configured or expected.
- Any public ingress is a separate reviewed change.

## Provision and configure

Review the management CIDRs in
`infra/proxmox/game-node/profiles/windrose.json`, then attach
`infra/proxmox/game-node/generated/windrose-cloud-init.yaml` as Proxmox vendor
data. Follow
[`infra/proxmox/game-node/README.md`](../infra/proxmox/game-node/README.md) for
VM creation and first-boot checks.

Create a Git-backed Portainer stack targeting
`docker/windrose/docker-compose.yml`. Configure these values only in the stack
environment UI:

| Variable | Purpose |
| --- | --- |
| `WINDROSE_TS_AUTHKEY` | Short-lived, pre-authorized sidecar key |
| `WINDROSE_TS_HOSTNAME` | Optional; defaults to `windrose-game` |
| `WINDROSE_SERVER_DESCRIPTION_JSON` | Complete generated server description |
| `WINDROSE_RESEED_SERVER_DESCRIPTION` | One-shot controlled replacement |

The description must retain its generated IDs and set
`UseDirectConnection` to `true` and `DirectConnectionServerPort` to `7777`.
Return the reseed variable to `false` immediately after a controlled reseed.

## Backups

Before enabling production runs:

1. Mount the NAS at `/mnt/nas-backups`.
2. Create a distinct writer scoped only to `windrose-backups`.
3. Install its rclone configuration at `/etc/game-backup/rclone.conf` as root
   mode `0600`.
4. Run `sudo game-backup --game windrose --dry-run`.
5. Start `game-backup@windrose.service` during a maintenance window.

The hook disables normal restart behavior through the common framework, stops
the container, and confirms both Docker state and the native process are cold
before `data` and `config` are archived. Active `RocksDB_v2` must never be
copied. Use the checksum-enforcing isolated restore procedure in
[`backups.md`](backups.md).

## Controlled update and rollback

1. Review the Renovate PR, upstream release notes, tag, digest, and amd64
   manifest.
2. Require a completed cold backup.
3. Merge and redeploy the reviewed Git revision through Portainer.
4. Require healthy Tailscale and Windrose containers.
5. Test a real client over TCP and UDP 7777.

Rollback by selecting the last known-good Git revision and redeploying. Do not
roll save data backward unless a restore incident requires it.
