# Palworld production stack

Portainer deploys `docker-compose.yml` to the dedicated Palworld Proxmox VM.
The stack uses Pocketpair's official digest-pinned server image and a dedicated
Tailscale sidecar. It publishes no host ports; player traffic, REST, metrics,
and administration remain private to the tailnet.

Required Portainer environment values:

- `TS_AUTHKEY`: short-lived, pre-authorized key for this stack
- `PALWORLD_ADMIN_PASSWORD`: at least 24 characters from
  `A-Za-z0-9._~!@#%^+=:-`
- `TS_HOSTNAME`: optional; defaults to `palworld-stack`

The root, network-disabled `palworld-init` service fixes persistent-save
ownership before the game starts as `user:usergroup` with
`no-new-privileges`. RCON is disabled and the authenticated REST API is enabled
on private port 8212 for health checks and application-consistent backups.

Provision the host with
`infra/proxmox/game-node/generated/palworld-cloud-init.yaml`, then follow
`ops/palworld.md`.
