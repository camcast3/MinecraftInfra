# Production operations runbook

Use this page as the entry point for provisioning, routine changes, incidents,
and recovery. Follow the linked implementation-specific runbooks rather than
copying values from this summary.

## Runbook flow

1. **New game:** provision the VM, enroll Tailscale and Portainer, configure
   secrets and backups, configure the Azure route, then complete the live gates.
2. **Routine change:** validate, back up, deploy through the owning automation,
   verify private health first, then verify the public player path.
3. **Incident:** stop the affected Azure forwarder, preserve evidence, choose
   rollback or restore, verify privately, then restore ingress.
4. **Lost node:** rebuild from Git, restore only from a checksum-verified
   archive, reconnect the control planes, and run every live-only gate again.

## Architecture and ownership

| Component | Responsibility | Owner path | Current production path |
| --- | --- | --- | --- |
| Azure VM | Public game ingress, Velocity, layer-4 forwarding | `platform/azure/edge/` | `docker/azure/` |
| Azure IaC | VM, NSG, Key Vault, storage, budget, alerts | `platform/azure/iac/` | `infra/azure/` |
| Minecraft VM | C2E2 backend and its backup containers | `games/minecraft/c2e2/` | `docker/proxmox/` |
| Palworld VM | Official Palworld server and private administration | `games/palworld/` | `docker/palworld/` |
| Windrose VM | Native Windrose server | `games/windrose/` | `docker/windrose/` |
| Game-node template | Palworld/Windrose host bootstrap and backup tools | `platform/proxmox/game-node/` | `infra/proxmox/game-node/` |
| Access data | Minecraft whitelist and generated operators | `games/minecraft/shared/` | `docker/shared/` |
| Automation | Validation, access, client, and layout tools | `tools/` | selected `scripts/` wrappers |

The Azure VM is the only public entry point. Minecraft, Palworld, and Windrose
run on separate private Proxmox VMs and are reached over Tailscale. Portainer
owns stack deployment; Git owns non-secret configuration. Never place secrets
in Git or a production `.env` file.

## Provision Palworld or Windrose

1. Review and, if necessary, narrow `managementCidrs` in the matching profile
   under `infra/proxmox/game-node/profiles/`.
2. Render the checked-in Debian 13 vendor data and review its diff:

   ```powershell
   pwsh .\infra\proxmox\game-node\Render-CloudInit.ps1 `
     -Profile palworld `
     -OutputPath .\infra\proxmox\game-node\generated\palworld-cloud-init.yaml

   pwsh .\infra\proxmox\game-node\Render-CloudInit.ps1 `
     -Profile windrose `
     -OutputPath .\infra\proxmox\game-node\generated\windrose-cloud-init.yaml
   ```

3. Follow [`infra/proxmox/game-node/README.md`](../infra/proxmox/game-node/README.md)
   to clone the Debian 13 template, attach the matching file as Proxmox vendor
   data, size the VM, wait for cloud-init, and verify Docker, UFW, Tailscale,
   unattended upgrades, and the QEMU guest agent.
4. Enroll host Tailscale with a short-lived, preauthorized, tagged key. Do not
   reuse the stack-sidecar key.
5. In Portainer, add a distinct **Docker Standalone / Edge Agent Standard**
   environment. Run Portainer's generated command on the VM and bind its state
   to `/data/<game>/portainer-edge-agent`. No inbound agent port belongs on the
   game VM.
6. Create the Git stack using the current production path:
   `docker/palworld/docker-compose.yml` or
   `docker/windrose/docker-compose.yml`. Do not repoint to `games/` until the
   compatibility gate is complete.

### Portainer and host secrets

Enter stack values individually in Portainer's environment UI:

| Stack | Required values |
| --- | --- |
| Minecraft/C2E2 | `TS_AUTHKEY`, `TS_HOSTNAME`, `VELOCITY_FORWARDING_SECRET`, `RCON_PASSWORD`, `BACKUP_STORAGE_ACCOUNT`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` |
| Palworld | `TS_AUTHKEY`, `PALWORLD_ADMIN_PASSWORD`; optional `TS_HOSTNAME` |
| Windrose | `WINDROSE_TS_AUTHKEY`, `WINDROSE_SERVER_DESCRIPTION_JSON`; optional `WINDROSE_TS_HOSTNAME`, one-shot `WINDROSE_RESEED_SERVER_DESCRIPTION` |

Palworld and Windrose offsite backup credentials are host secrets, not stack
variables. Put only the matching container-scoped service principal in
`/etc/game-backup/rclone.conf` with mode `0600`. Mount and verify the NAS before
enabling the timer. Full steps are in [`backups.md`](backups.md).

For Windrose, retain the generated `PersistentServerId` and `WorldIslandId`,
enable direct connection on port 7777, and return
`WINDROSE_RESEED_SERVER_DESCRIPTION` to `false` after a controlled reseed.

## Azure backup account and alerts

`stmcbackupsprod` is a dedicated `Standard_GRS` account. Its three containers
are private, shared-key access is disabled, blob and container soft delete are
14 days, and each game writer is scoped only to its own container. The storage
data-plane endpoint is currently internet-addressable but requires Microsoft
Entra OAuth; this implementation does **not** claim an Azure Private Endpoint.

The severity-3 metric alert is a cost/runaway-write guard: over a one-hour
window it totals primary, OAuth-authenticated `PutBlock` and `PutBlob` ingress
and compares it with `backupIngressThresholdBytes` (15 GiB in production).
Expected daily backups should remain below it. It does not prove backup
success; Loki failure, stale, and absent signals do that.

On an alert:

1. Check whether multiple game jobs overlapped or an archive grew legitimately.
2. Check the game backup result and freshness signals.
3. List blobs and sizes read-only; do not delete evidence.
4. Disable the affected writer or timer if writes are uncontrolled.
5. Change the threshold only after measuring the new normal baseline and
   updating both the parameter and cost forecast.

## Public forwarding and private endpoints

Only these player listeners are public:

| Public listener | Private destination |
| --- | --- |
| `25565/tcp` | Velocity, then C2E2 over Tailscale |
| `8211/udp` | Palworld over Tailscale |
| `7777/tcp` and `7777/udp` | Windrose over Tailscale |

Palworld REST `8212`, RCON, SSH, Portainer, metrics, and Alloy endpoints are
never public. Admin and monitoring access must use explicit Tailscale grants.
See [`azure-edge.md`](azure-edge.md) for Key Vault route secrets, DNS, firewall
reconciliation, and the minimum edge-to-game policy.

### Disable ingress

For an immediate game-specific stop on the Azure VM:

```bash
cd /opt/minecraft
docker compose stop palworld-forwarder
docker compose stop windrose-tcp-forwarder windrose-udp-forwarder
docker compose stop velocity
```

Stop only the affected service. Stop `tailscale` to remove all public game
listeners in a severe incident. These are temporary controls: the next deploy
can recreate services. For a durable closure, make and deploy a reviewed
Compose plus Bicep/NSG change, then verify the listener is absent externally.
Do not rely on UFW alone for Docker-published ports.

Restore ingress only after private health, route, ACL, NSG, UFW, and public
client checks pass.

## Normal update flow

- **OS:** unattended upgrades install daily security updates and use staggered
  off-peak reboots. Investigate a failed unit rather than manually upgrading
  around it.
- **Pinned images:** Renovate opens a digest change. Review upstream notes,
  architecture, and the diff. Require a fresh successful backup before merge.
- **Minecraft/C2E2:** the publish workflow updates the SHA-pinned packwiz URL,
  server MOTD, and immutable client candidate. Portainer redeploys after merge;
  stable client pointers move only after the public server advertises the new
  version. Follow [`publish-runbook.md`](publish-runbook.md).
- **Palworld:** automatic GitOps redeploy is disabled. Save, announce, stop,
  merge, then use **Pull and redeploy**. Follow [`palworld.md`](palworld.md).
- **Windrose:** require a completed cold backup, merge the reviewed digest,
  let the configured GitOps poll redeploy, and verify both TCP and UDP health.
  Its stack details are in
  [`docker/windrose/README.md`](../docker/windrose/README.md).

For every game: verify the private service before opening or testing the public
path, and never combine an image rollback with a save-data rollback unless the
incident specifically requires both.

## Transactional `nz` client rollout

`release-nz.yml` gates every production client with unit tests, vet, full E2E,
an immutable compatibility corpus, disposable package validation, distribution
policy, static launch, installer checksum verification, and current public
server health. It first publishes immutable `nz-v<commit>` assets and only then
refreshes the `nz-latest` bootstrap.

`nz setup`, `nz update`, and `nz migrate` use the same transaction engine:

1. reject unsupported manifest, preserve-list, or transaction schemas;
2. acquire a per-instance lock and recover any interrupted journal;
3. create an off-instance immutable backup with per-file SHA-256 metadata;
4. prepare and validate a sibling staging directory;
5. apply only declared preserved paths and version-bounded migrations;
6. rename live to rollback and atomically promote the stage;
7. write the version marker last, then remove the transient rollback tree.

Do not manually delete `.nz-transaction.json`, sibling stage/rollback
directories, or `.negativezone-backups`. Re-run the same `nz` command so its
journal recovery can restore a coherent state. Promote a client only through
the release workflow; never replace assets in an immutable release.

## Application-aware backups and isolated restores

| Game | Consistency boundary |
| --- | --- |
| C2E2 | `itzg/mc-backup` coordinates with Minecraft over private RCON before copying; local, NAS, and Azure schedules are staggered. |
| Palworld | REST announce and save, graceful shutdown, confirmed stop, archive, then health-verified restart. |
| Windrose | Restart policy disabled, confirmed cold stop, independent process check, archive of data/config, then health-verified restart. Active `RocksDB_v2` is never copied. |

Palworld and Windrose archives are complete only when their checksum and
`*.complete.json` exist. `game-restore` verifies those files, rejects unsafe
paths and wrong-game metadata, refuses live destinations, and never overwrites
an existing directory.

Always restore to `/data/restore-validation/<game>-<date>`, inspect it or attach
it to a disposable stack, and record the result. A live replacement is a
separate maintenance decision: disable ingress, stop the game, preserve the
current live directory, copy only from the verified isolated tree, correct
ownership, start privately, and reopen ingress only after health and a real
client check. See [`backups.md`](backups.md).

## Rollback

Choose the narrowest rollback:

- **Config/image:** redeploy the last known-good Git revision in Portainer.
- **Azure edge/IaC:** revert the offending commit and run `deploy-azure.yml`;
  keep `setCustomData=false` for an existing VM.
- **C2E2 release:** revert the publish commit and repoint both stable client
  pointers to the matching immutable release.
- **`nz` transaction failure:** rerun the command and allow journal recovery.
  For a committed setup regression, use the generated `(old)` Prism instance or
  the verified `.bak` while the stable pointer is rolled back.
- **Save corruption:** use the isolated restore process. Do not roll save data
  backward merely because an image was rolled back.

After rollback, verify private health, backup freshness, public connectivity,
and the advertised/client version before declaring recovery.

## Disaster recovery

1. Disable public ingress and preserve logs, transaction journals, backup
   completion metadata, and the failed disks where possible.
2. Select the newest checksum-valid archive that predates the incident. Prefer
   local, then NAS, then Azure according to availability—not merely age.
3. Rebuild the Azure edge from Bicep/workflow or rebuild the game VM from the
   checked-in rendered cloud-init. Do not clone secrets from a failed disk.
4. Re-enroll host and stack Tailscale nodes with new short-lived keys, register
   the Portainer Edge environment, and re-enter secrets from their authorities.
5. Configure the NAS and the game's scoped Azure writer. Prove it cannot list a
   sibling game's container.
6. Restore into isolation, validate, then promote during a maintenance window.
7. Deploy the current production Git revision, update the backend Tailscale IP
   in Key Vault, and let the Azure workflow refresh the route.
8. If the Azure Public IP changed, update the DNS-only Cloudflare A records.
9. Run the full live-only checklist, including a real client join, backup cycle,
   update, and rollback. Re-enable ingress last.

GRS and soft delete improve durability but do not replace tested restores or
protect against every account-level disaster. Keep NAS and Azure credentials
separate and retain the local tier.

## Production readiness and live-only evidence

Run the reusable pre-production validator:

```powershell
pwsh .\tools\validation\Invoke-MultigameRolloutValidation.ps1
```

Then record operator, timestamp, revision, and evidence for every unchecked
item in [`multigame-rollout-checklist.md`](multigame-rollout-checklist.md).
Palworld must complete its live-only gates before Windrose begins. Fixture
echoes, mocked backups, and Compose simulations are not substitutes for a real
client join, real shutdown, real offsite write, or observed rollback.

## Incremental repository compatibility paths

The game/platform/tool directories are owners, but production still consumes
documented compatibility paths. Before any repoint:

1. Read the per-mapping gate in
   [`tools/layout/compatibility-paths.json`](../tools/layout/compatibility-paths.json).
2. Keep owner and compatibility copies byte-equal:

   ```powershell
   pwsh .\tools\layout\Sync-CompatibilityPaths.ps1
   pwsh .\tools\layout\Test-RepositoryLayout.ps1
   ```

3. Preserve Portainer stack/project names, Azure resource names, release asset
   names, raw URLs, and dual workflow path filters.
4. Repoint one consumer in a maintenance window, verify its explicit gate for a
   full release/soak period, then retire the compatibility path separately.

Never bulk-move live paths merely to make the tree look cleaner.

## Whitelist-derived level-3 operators

Git is authoritative for Minecraft access. Edit
`games/minecraft/shared/whitelist.json`, then generate operators:

```powershell
pwsh .\tools\access\sync-ops.ps1
pwsh .\tools\layout\Sync-CompatibilityPaths.ps1
pwsh .\tools\access\sync-ops.ps1 -Check
```

Every whitelist entry becomes an operator with `"level": 3` and
`"bypassesPlayerLimit": false`. Never edit `ops.json` directly. In-game
`/whitelist` and `/op` changes are temporary and are replaced on restart.

## Authoritative platform references

- [Palworld dedicated server guide](https://docs.palworldgame.com/)
  and [REST API exposure warning](https://docs.palworldgame.com/api/rest-api/palwold-rest-api/)
- [Windrose server image](https://hub.docker.com/r/windroseserver/windroseserver)
- [Portainer Git stacks](https://docs.portainer.io/user/docker/stacks/add)
  and [Edge Agent Standard](https://docs.portainer.io/admin/environments/add/docker/edge)
- [Proxmox `qm` cloud-init options](https://pve.proxmox.com/pve-docs/qm.1.html)
- [Tailscale auth keys](https://tailscale.com/docs/features/access-control/auth-keys)
  and [access control](https://tailscale.com/docs/features/access-control)
- [Azure Storage redundancy](https://learn.microsoft.com/azure/storage/common/storage-redundancy),
  [blob soft delete](https://learn.microsoft.com/azure/storage/blobs/soft-delete-blob-overview),
  and [Azure Monitor alert types](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-types)
- [Docker packet filtering and UFW behavior](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
