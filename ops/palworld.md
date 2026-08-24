# Palworld operations

The production source is
[`docker/palworld/docker-compose.yml`](../docker/palworld/docker-compose.yml).
Portainer deploys it to the dedicated Proxmox VM using Pocketpair's official
digest-pinned image.

## Network boundary

- Do not forward a home-router port to the Palworld VM.
- The Compose stack publishes no host ports.
- Player UDP 8211, authenticated REST TCP 8212, metrics, and container
  administration share the stack's Tailscale network namespace.
- RCON is forced off on every start.
- This change does not create a public edge route. Player access remains
  tailnet-only until a separate reviewed ingress change is deployed.

Pocketpair warns that the REST API must not be exposed directly to the
internet. Restrict tailnet grants to the operators and automation that require
it.

## Provision the host

Review the management CIDRs in
`infra/proxmox/game-node/profiles/palworld.json`, then attach
`infra/proxmox/game-node/generated/palworld-cloud-init.yaml` as Proxmox vendor
data. Follow
[`infra/proxmox/game-node/README.md`](../infra/proxmox/game-node/README.md) for
VM creation and first-boot checks.

Cloud-init creates `/data/palworld`, installs Docker, Tailscale, backup tools,
and the Palworld REST quiesce hook, and enables the backup timers. It does not
enroll Tailscale, Portainer, or backup credentials.

## Configure Portainer

Create a Git-backed stack targeting `docker/palworld/docker-compose.yml`.
Disable automatic GitOps redeploys so image changes use the controlled update
procedure. Configure:

| Variable | Purpose |
| --- | --- |
| `TS_AUTHKEY` | Short-lived, pre-authorized key for the stack sidecar |
| `TS_HOSTNAME` | Optional; defaults to `palworld-stack` |
| `PALWORLD_ADMIN_PASSWORD` | REST password; 24+ safe-set characters |

The password may contain `A-Za-z0-9._~!@#%^+=:-`. It is rendered into the
persistent Palworld INI at startup and must never be committed.

The network-disabled `palworld-init` one-shot service assigns save ownership to
the image's `user:usergroup` account. The game then runs non-root with
`no-new-privileges`.

## Private health and administration

From an authorized tailnet client:

```bash
curl --fail --user "admin:${PALWORLD_ADMIN_PASSWORD}" \
  http://palworld-stack:8212/v1/api/info

curl --fail --user "admin:${PALWORLD_ADMIN_PASSWORD}" \
  http://palworld-stack:8212/v1/api/metrics
```

Host and container metrics are available privately at ports 9100 and 8080.
Alloy ships Docker and backup event logs to the existing tailnet Loki endpoint.

## Backups

Before enabling production runs:

1. Mount the NAS at `/mnt/nas-backups`.
2. Create a distinct Palworld Azure backup writer scoped only to
   `palworld-backups`.
3. Put its rclone credentials in `/etc/game-backup/rclone.conf` as root mode
   `0600`.
4. Verify the identity can access `palworld-backups` and cannot access another
   game's container.
5. Run:

   ```bash
   sudo game-backup --game palworld --dry-run
   sudo systemctl start game-backup@palworld.service
   sudo systemctl status game-backup@palworld.service
   ```

The hook checks Docker health, uses the REST credential only inside the game
container, announces, saves, requests graceful shutdown, and leaves the common
framework to confirm the cold stop, archive, restart, and publish. Use the
checksum-enforcing isolated restore procedure in [`backups.md`](backups.md).

## Controlled image update

1. Review the Renovate PR, upstream release notes, digest, and `linux/amd64`
   manifest.
2. Require a successful application-consistent backup.
3. Merge the reviewed change.
4. In Portainer, use **Pull and redeploy**.
5. Require healthy Tailscale and Palworld containers plus a successful private
   REST `/info` call.
6. Test a real client over the approved private or separately deployed ingress
   path.

Rollback by selecting the last known-good Git revision in Portainer and
redeploying. Do not roll save data backward unless a restore incident requires
it.
