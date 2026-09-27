# Palworld operations

The production source is
[`docker/palworld/docker-compose.yml`](../docker/palworld/docker-compose.yml).
Docker Compose deploys it to the dedicated Proxmox VM using the digest-pinned
`thijsvanloef/palworld-server-docker` image.

## Network boundary

- Do not forward a home-router port to the Palworld VM.
- Player UDP 8211 binds only to the Palworld VM's `192.168.3.120` LAN address.
- The host permits that Docker-published port only from `192.168.69.0/24` and
  `192.168.2.0/24`; all other source networks are dropped in `DOCKER-USER`.
- Authenticated REST TCP 8212, metrics, and container administration remain
  inside the stack's Tailscale network namespace.
- RCON is forced off on every start.
- This change does not create a public edge route. Player access remains
  LAN-or-tailnet-only until a separate reviewed ingress change is deployed.

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

## Configure and deploy

Supply these values from a root-readable runtime environment file or shell.
They can later be moved into Portainer stack variables without changing the
Compose model:

| Variable | Purpose |
| --- | --- |
| `TS_AUTHKEY` | Short-lived, pre-authorized key for the stack sidecar |
| `TS_HOSTNAME` | Optional; defaults to `palworld-stack` |
| `PALWORLD_ADMIN_PASSWORD` | REST password; 24+ safe-set characters |
| `PALWORLD_LAN_IP` | Required LAN bind address; use `192.168.3.120` |
| `PALWORLD_PUID` | Host data-owner UID; currently `1002` |
| `PALWORLD_PGID` | Host data-owner GID; currently `1002` |
| `PALWORLD_SERVER_PASSWORD` | Optional player password |
| `PALWORLD_DASHBOARD_PASSWORD` | Initial self-hosted dashboard administrator password |

The password may contain `A-Za-z0-9._~!@#%^+=:-`. It is rendered into the
persistent Palworld INI at startup and must never be committed.

The Docker forwarding policy is installed by
`game-node-docker-firewall.service` from the rendered cloud-init. For an
existing VM, install or update that policy before setting `PALWORLD_LAN_IP`
and redeploying the Compose stack. UniFi must separately allow UDP 8211 from
`192.168.69.0/24` and `192.168.2.0/24` to `192.168.3.120`, while retaining
the default DMZ isolation for every other source and destination port.

The image starts as root only to install/update the server and assign
`/palworld` to `PALWORLD_PUID:PALWORLD_PGID`; it then launches Palworld through
`gosu` while Compose enforces `no-new-privileges`. Its internal backup scheduler
is disabled in favor of the repository's host-managed backup framework.

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

## Self-hosted dashboard

The RNZ01 dashboard shares the Palworld Tailscale namespace and calls the REST
API only at `127.0.0.1:8212`. Its host publication is limited to VM loopback.
Open an SSH tunnel:

```powershell
ssh -N -L 3000:127.0.0.1:3000 -p 7822 palworld@192.168.3.120
```

Browse to `http://127.0.0.1:3000`. Retrieve the initial password locally on the
VM, log in, and replace it from the dashboard settings. Do not publish port
3000 through UniFi or the internet.

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
4. Pull the reviewed image and recreate the Compose stack.
5. Require healthy Tailscale and Palworld containers plus a successful private
   REST `/info` call.
6. Test a real client over the approved private or separately deployed ingress
   path.

Rollback by selecting the last known-good Git revision in Portainer and
redeploying. Do not roll save data backward unless a restore incident requires
it.
