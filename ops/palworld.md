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
- Dashboard TCP 3000 binds only to `192.168.3.120` and permits
  `192.168.69.0/24`; all other source networks are dropped in `DOCKER-USER`.
- Public player traffic enters the existing Azure VM on UDP 8211, reaches an
  Nginx stream proxy in the Azure Tailscale namespace, and is forwarded to the
  Palworld stack's tailnet IP on UDP 8211.
- Authenticated REST TCP 8212, metrics, and container administration remain
  inside the stack's Tailscale network namespace.
- RCON is forced off on every start.

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
| `PALWORLD_SERVER_PASSWORD` | Required player-only password; never reuse an admin credential |
| `PALWORLD_DASHBOARD_PASSWORD` | Initial self-hosted dashboard administrator password |

The password may contain `A-Za-z0-9._~!@#%^+=:-`. It is rendered into the
persistent Palworld INI at startup and must never be committed.

Only Steam and Xbox clients are allowed. PlayStation and Mac clients are
rejected by the server's `CrossplayPlatforms` setting.

The Docker forwarding policy is installed by
`game-node-docker-firewall.service` from the rendered cloud-init. For an
existing VM, install or update that policy before setting `PALWORLD_LAN_IP`
and redeploying the Compose stack. UniFi must separately allow UDP 8211 from
`192.168.69.0/24` and `192.168.2.0/24`, plus TCP 3000 from
`192.168.69.0/24`, to `192.168.3.120`, while retaining the default DMZ
isolation for every other source and destination port.

The image starts as root only to install/update the server and assign
`/palworld` to `PALWORLD_PUID:PALWORLD_PGID`; it then launches Palworld through
`gosu` while Compose enforces `no-new-privileges`. Its internal backup scheduler
is disabled in favor of the repository's host-managed backup framework.
`ITEM_CORRUPTION_MULTIPLIER=0.000000` disables food and other perishable-item
expiration. `COLLECTION_DROP_RATE=2.000000` doubles drops from all gatherable
resources, including stone, wood, and ore.

## Public player endpoint

After the Palworld Tailscale sidecar is online, record its IPv4 address in the
Azure Key Vault:

```bash
az keyvault secret set \
  --vault-name kv-minecraft-prod \
  --name palworld-tailscale-ip \
  --value '100.x.x.x'
```

Deploy `infra/azure/**` and `docker/azure/**` through
`.github/workflows/deploy-azure.yml`. The deployment opens UDP 8211 in the Azure
NSG and host UFW, renders `/data/minecraft/nginx/nginx.conf`, and starts the
digest-pinned `palworld-proxy` container. Tailscale grants must allow
`proxy-azure` to reach the Palworld stack on UDP 8211.

The existing DNS-only Cloudflare A record for `mc.negativezone.cc` already
points to the Azure VM. Players can therefore use:

```text
mc.negativezone.cc:8211
```

No Cloudflare proxying is required or supported for this game UDP traffic; keep
the record set to **DNS only**. A separate `palworld.negativezone.cc` DNS-only A
record pointing to the same Azure public IP is optional if a game-specific
hostname is preferred:

```text
palworld.negativezone.cc:8211
```

Nginx terminates the public UDP session and originates the tailnet session, so
the Palworld server sees the Azure proxy's tailnet address rather than each
player's public IP. Client addresses remain available in the Nginx access log.
Do not expose REST 8212 or the dashboard through this route.

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
API only at `127.0.0.1:8212`. Its host publication binds to
`192.168.3.120:3000` and the host firewall admits only `192.168.69.0/24`.
From that VLAN, browse to:

```text
http://192.168.3.120:3000
```

Retrieve the initial password locally on the VM, log in, and replace it from
the dashboard settings. Do not expose TCP 3000 to other VLANs or the internet.

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
