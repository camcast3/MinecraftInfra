# Palworld operations

The Portainer CE GitOps stack is
[`docker/palworld/docker-compose.yml`](../docker/palworld/docker-compose.yml).
It uses Pocketpair's official `ghcr.io/pocketpairjp/palserver` image. The
server tag and digest are intentionally pinned, and Renovate may only propose
updates through a reviewed pull request.

## Network boundary

- Do not forward any home-router port to the Palworld VM.
- The Azure edge publishes **UDP 8211 only** and forwards it to the stack's
  Tailscale IPv4 address from Key Vault.
- Do not forward TCP 8212 or TCP 25575. RCON is forced off on every start.
- The REST API, node-exporter (`9100`), and cAdvisor (`8080`) share the
  per-stack Tailscale network namespace and have no host port publication.
- Pocketpair explicitly warns that the REST API must not be exposed directly
  to the internet.

The backend host cloud-init allows no public game port, and the backend
Compose file publishes none. See
[`azure-edge.md`](azure-edge.md) for Key Vault routing, ACLs, DNS, and edge
firewall policy.

## Portainer setup

Create a Git-backed stack targeting `docker/palworld/docker-compose.yml`.
Disable automatic GitOps redeploys; update only with the controlled procedure
below. Configure these stack environment variables in Portainer:

| Variable | Purpose |
| --- | --- |
| `TS_AUTHKEY` | Short-lived, pre-authorized auth key for this stack's node |
| `TS_HOSTNAME` | Optional tailnet name; defaults to `palworld-stack` |
| `PALWORLD_ADMIN_PASSWORD` | REST password; 24+ safe-set characters |

The password's allowed characters are `A-Za-z0-9._~!@#%^+=:-`.

The admin password is rendered into the persistent Palworld INI at container
start. It is never stored in Git. Rotate it by changing the Portainer variable
and redeploying.

Each deploy first runs the root, network-disabled `palworld-init` one-shot
service to assign the persistent save to the image's `user:usergroup` account.
The game then starts explicitly as that non-root account with
`no-new-privileges`; do not bypass or manually disable the init dependency.

## Health and administration

The container health check authenticates to:

```text
GET http://127.0.0.1:8212/v1/api/info
```

From a tailnet client, use the stack's Tailscale IP or MagicDNS name:

```bash
curl --fail --user "admin:${PALWORLD_ADMIN_PASSWORD}" \
  http://palworld-stack:8212/v1/api/info

curl --fail --user "admin:${PALWORLD_ADMIN_PASSWORD}" \
  http://palworld-stack:8212/v1/api/metrics
```

The same tailnet boundary exposes Prometheus-format host/container metrics at
`http://palworld-stack:9100/metrics` and
`http://palworld-stack:8080/metrics`. Alloy ships Docker logs to the repository's
existing tailnet Loki endpoint and persists positions under
`/data/palworld/monitoring/alloy`.

## Controlled image update

1. Review the Renovate PR. Confirm the official tag, digest, release notes,
   and `linux/amd64` manifest before merging.
2. Keep Portainer automatic GitOps updates disabled.
3. Ask Palworld to save, then announce a shutdown:

   ```bash
   curl --fail --request POST \
     --user "admin:${PALWORLD_ADMIN_PASSWORD}" \
     http://palworld-stack:8212/v1/api/save

   curl --fail --request POST \
     --user "admin:${PALWORLD_ADMIN_PASSWORD}" \
     --header "Content-Type: application/json" \
     --data '{"waittime":60,"message":"Server update in one minute"}' \
     http://palworld-stack:8212/v1/api/shutdown
   ```

4. During that minute, stop `palworld-server` in Portainer (or run
   `docker stop --time 120 palworld-server`) so its restart policy cannot race
   the planned update.
5. Merge the reviewed PR, then use **Pull and redeploy** in Portainer.
6. Require healthy `tailscale` and `palworld` containers, a successful REST
   `/info` call, and a test connection through the Azure edge on UDP 8211
   before closing the update.

Rollback by selecting the last known-good Git revision in Portainer and
redeploying. Do not roll save data backward unless a restore runbook explicitly
requires it.

## Backups

The host `game-backup@palworld.timer` performs the complete workflow: private
REST announce, save, graceful shutdown, confirmed stop, local archive,
health-verified restart, then NAS and Azure Cold publication. Retention is 14,
7, and 90 days respectively. The stack mounts the host backup event log into
Alloy for failure and staleness reporting.

Never copy the live save directly. Use the checksum-enforcing isolated restore
workflow in [`backups.md`](backups.md); it refuses live destinations.
