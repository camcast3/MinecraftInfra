# Palworld production stack

Docker Compose deploys `docker-compose.yml` to the dedicated Palworld Proxmox
VM. The stack uses the digest-pinned
[`thijsvanloef/palworld-server-docker`](https://github.com/thijsvanloef/palworld-server-docker)
image and a dedicated Tailscale sidecar. Player UDP 8211 is bound to the VM's
LAN address and limited by the host firewall to `192.168.69.0/24` and
`192.168.2.0/24`. REST, metrics, and administration remain private to the
tailnet.

Required runtime environment values:

- `TS_AUTHKEY`: short-lived, pre-authorized key for this stack
- `PALWORLD_ADMIN_PASSWORD`: at least 24 characters from
  `A-Za-z0-9._~!@#%^+=:-`
- `PALWORLD_LAN_IP`: `192.168.3.120`
- `PALWORLD_PUID`: host UID that owns `/data/palworld/server`
- `PALWORLD_PGID`: host GID that owns `/data/palworld/server`
- `PALWORLD_DASHBOARD_PASSWORD`: initial self-hosted dashboard administrator password
- `TS_HOSTNAME`: optional; defaults to `palworld-stack`

The image installs and updates the Palworld server under
`/data/palworld/server`, then drops from root to the configured UID/GID with
`gosu`. Built-in backups and RCON are disabled because the host backup framework
uses the authenticated REST API on private port 8212.

The self-hosted dashboard is available only through the tailnet or an SSH
tunnel. From an authorized workstation:

```powershell
ssh -N -L 3000:127.0.0.1:3000 -p 7822 palworld@192.168.3.120
```

Then open `http://127.0.0.1:3000`. The initial password is stored only on the
VM and should be changed from the dashboard after first login.

Provision the host with
`infra/proxmox/game-node/generated/palworld-cloud-init.yaml`, then follow
`ops/palworld.md`.
