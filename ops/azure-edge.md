# Azure game edge

The Azure VM is the only public game ingress. Its existing containerized
Tailscale node owns one shared network namespace containing Velocity and three
digest-pinned layer-4 forwarders:

| Public listener | Destination over Tailscale |
| --- | --- |
| `25565/tcp` | Velocity `localhost:25577`, then C2E2 |
| `8211/udp` | Palworld `8211/udp` |
| `7777/tcp` | Windrose `7777/tcp` |
| `7777/udp` | Windrose `7777/udp` |

No public listener exists for Palworld REST `8212`, RCON, SSH, Portainer, or
any metrics endpoint. The NSG, live UFW policy, and Compose publication must
all remain limited to the table above.

## Backend routes in Key Vault

The edge intentionally uses backend IPv4 addresses rather than MagicDNS:
`TS_ACCEPT_DNS=false` keeps the read-only Tailscale container from changing
resolver state. After each backend sidecar enrolls, read its address:

```bash
docker exec palworld-tailscale tailscale ip -4
docker exec windrose-tailscale tailscale ip -4
```

Store the results without committing them:

```bash
az keyvault secret set --vault-name kv-minecraft-prod \
  --name palworld-tailscale-ip --value '100.x.x.x'
az keyvault secret set --vault-name kv-minecraft-prod \
  --name windrose-tailscale-ip --value '100.x.x.x'
```

`docker/azure/refresh-env.sh` validates configured backend routes against
Tailscale's `100.64.0.0/10` range, writes root-only route files, and restarts
only affected running forwarders. Until a planned game's secret exists, its
listener uses the unassigned `100.64.0.0` sink so Minecraft/Velocity deploys
remain unaffected. A transient Key Vault read failure retains the last valid
route. The next normal Azure workflow run applies a newly configured route.
Rebuilding a backend changes Key Vault, not Git or Bicep.

## Tailscale ACLs and DNS

Use tagged, preauthorized auth keys so the edge can reach only player ports.
The following HUJSON is an illustrative minimum; merge it with the tailnet's
existing owners, admin, monitoring, and SSH policy:

```json
{
  "tagOwners": {
    "tag:azure-edge": ["autogroup:admin"],
    "tag:minecraft-game": ["autogroup:admin"],
    "tag:palworld-game": ["autogroup:admin"],
    "tag:windrose-game": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["tag:azure-edge"],
      "proto": "tcp",
      "dst": ["tag:minecraft-game:25565", "tag:windrose-game:7777"]
    },
    {
      "action": "accept",
      "src": ["tag:azure-edge"],
      "proto": "udp",
      "dst": ["tag:palworld-game:8211", "tag:windrose-game:7777"]
    }
  ]
}
```

Keep admin and monitoring grants in separate ACL entries for explicit operator
or collector identities. Do not grant `tag:azure-edge` access to `8212`,
RCON, Portainer, SSH, or metrics ports.

MagicDNS remains useful for operators (`palworld-stack`,
`windrose-game`, and `proxy-azure`), but it is not part of the forwarding
data path. Public Cloudflare records are DNS-only A records that all point to
the Azure Public IP:

- `mc.negativezone.cc` (Minecraft default port `25565`)
- `palworld.negativezone.cc` (UDP `8211`)
- `windrose.negativezone.cc` (TCP and UDP `7777`)

Do not enable Cloudflare proxying; it does not proxy these arbitrary game
protocols.

## Firewall and health reconciliation

Azure `customData` cannot be changed on an existing VM. Therefore
`deploy-azure.yml` runs `docker/azure/reconcile-firewall.sh` on every deploy.
The script replaces UFW state with the four player rules before Compose starts.
Fresh cloud-init calls the same script, preserving bootstrap/live parity.

Each forwarder starts only after the Tailscale sidecar is healthy, validates
its route file, execs `socat` as PID 1, and checks the expected TCP or UDP
listener in `/proc/net`. The deploy uses `docker compose up --wait`; an
unhealthy listener fails the deployment rather than silently dropping traffic.
