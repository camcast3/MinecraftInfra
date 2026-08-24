# Server backup operations

## Application consistency

| Game | Backup boundary |
| --- | --- |
| C2E2 | `itzg/mc-backup` coordinates saves over container-private RCON. Its local, NAS, and Azure jobs are staggered so save-off windows do not overlap. |
| Palworld | Announce, REST save, graceful shutdown, confirmed stop, archive, and health-verified restart. |
| Windrose | Confirmed cold stop plus an independent native-process check before `data`, `config`, or `RocksDB_v2` is read; then health-verified restart. |

Copying a live data directory is not a supported backup for any game.

## Storage layout

- `stmcminecraftprod/minecraft-modpack` remains the public, anonymous-read
  player distribution container.
- `stmcbackupsprod/c2e2-backups` is the dedicated private C2E2 backup target.
- `stmcbackupsprod/palworld-backups` and
  `stmcbackupsprod/windrose-backups` are private Azure Cold targets for the
  dedicated game VMs.
  Shared-key and anonymous blob access are disabled; the Proxmox service
  principals have `Storage Blob Data Contributor` only on their matching
  containers. Keep the three writer identities separate.
- Palworld and Windrose containers are not deployed until their distinct
  service-principal object IDs are set in `prod.bicepparam`. They never fall
  back to the C2E2 identity.
- If changing a writer after its first deployment, delete the existing
  container-scoped role assignment before redeploying. The role-assignment
  resource ID is stable per container so Azure fails closed instead of keeping
  both the old and new principals.
- Historical blobs in
  `stmcminecraftprod/minecraft-backups/c2e2/` are intentionally not copied or
  deleted by this migration.

Set `BACKUP_STORAGE_ACCOUNT=stmcbackupsprod` in the Portainer stack environment
after the Bicep deployment creates the account and scoped role assignment. The
compose file uses that production name as a migration-safe default.

## Palworld and Windrose host automation

The game-node cloud-init installs host-level `game-backup@.service` and
`game-backup@.timer` units. No backup container or Docker socket mount is used.
Each daily run creates one gzip archive plus a SHA-256 file and writes
`*.complete.json` last. Consumers must ignore any set without that completion
metadata.

Retention is enforced independently:

- `/data/<game>/backups/local`: 14 days
- mounted `/mnt/nas-backups/<game>`: 7 days
- private `stmcbackupsprod/<game>-backups`, access tier `Cold`: 90 days

Before enabling production runs:

1. Mount the NAS at `/mnt/nas-backups`; the job refuses a plain local
   directory at that path.
2. Copy `/etc/game-backup/rclone.conf.example` to
   `/etc/game-backup/rclone.conf`, insert only that game's service-principal
   credentials, then set mode `0600`.
3. Verify `rclone lsd azure:<game>-backups` succeeds and cannot list another
   game's container.
4. Run `sudo game-backup --game <game> --dry-run`, then start the unit:

   ```bash
   sudo systemctl start game-backup@palworld.service
   sudo systemctl status game-backup@palworld.service
   sudo systemctl list-timers 'game-backup*'
   ```

Palworld uses its container-private REST API to announce the backup, save,
request graceful shutdown, and confirm the container stopped. The credential
is expanded only inside `palworld-server`. Windrose is stopped and independently
confirmed cold before `data` or `config` is read; the job aborts if a
`WindroseServer-Linux-Shipping` process remains, so active `RocksDB_v2` is
never copied. Both games restore the original restart policy and must become
Docker-healthy before NAS or Azure publication begins.

A restart-required marker is persisted before a restart policy is changed.
`game-backup-recover@<game>.service` runs at boot and before every scheduled
backup, restoring and health-checking a server if a prior run was interrupted.

## Failure and freshness signals

The host writes structured events to
`/data/<game>/backups/health/events.log`; each stack's Alloy service ships that
file to Loki. Atomic epoch markers named `<game>-<destination>.success` drive
the 15-minute freshness timer. The default stale threshold is 36 hours.

```text
game_backup_result game=palworld destination=azure status=failure exit_code=1
game_backup_health game=windrose destination=azure status=stale age_seconds=129900
```

Recommended alerts:

```logql
count_over_time({job="game-backup", backup_signal="game_backup_result", backup_status="failure"}[15m]) > 0
count_over_time({job="game-backup", backup_signal="game_backup_health", backup_status="stale"}[15m]) > 0
absent_over_time({job="game-backup", backup_signal="game_backup_health"}[30m])
```

## Isolated restore verification

`game-restore` verifies the completion metadata, SHA-256 checksum, and archive
paths. It refuses live game data/config destinations and refuses to overwrite
an existing directory.

```bash
sudo game-restore \
  --game palworld \
  --archive /data/palworld/backups/local/palworld-YYYYMMDDTHHMMSSZ.tar.gz \
  --destination /data/restore-validation/palworld-YYYYMMDD \
  --dry-run

sudo game-restore \
  --game palworld \
  --archive /data/palworld/backups/local/palworld-YYYYMMDDTHHMMSSZ.tar.gz \
  --destination /data/restore-validation/palworld-YYYYMMDD
```

Inspect or launch a separate disposable validation stack against the isolated
directory. This tooling never replaces live save data.

### Promoting a verified restore

Promotion is intentionally manual and requires a maintenance window:

1. Disable the affected public forwarder using
   [`runbook.md`](runbook.md#disable-ingress).
2. Stop the game and prove no game process remains.
3. Preserve the current live directory under a new incident-specific name.
4. Copy from the already verified isolated restore, never directly from an
   archive or incomplete upload.
5. Restore the service user's ownership and start the game privately.
6. Verify game health, logs, save identity, and a real client connection.
7. Take a new application-aware backup before restoring public ingress.

Do not reuse the isolated destination or overwrite the pre-incident tree.

## Health signals

`backup-azure` emits one structured line after each attempt and updates a
persistent success marker. The non-networked `backup-health` sidecar checks that
marker every 15 minutes and emits only health-state transitions:

```text
minecraft_backup_result game=c2e2 destination=azure status=success
minecraft_backup_result game=c2e2 destination=azure status=failure exit_code=1
minecraft_backup_health game=c2e2 destination=azure status=healthy age_seconds=300
minecraft_backup_health game=c2e2 destination=azure status=stale age_seconds=129900
```

Promtail extracts `backup_signal`, `backup_game`, `backup_destination`, and
`backup_status`.
Recommended Loki alert expressions:

```logql
count_over_time({instance="proxmox-c2e2", backup_signal="minecraft_backup_result", backup_game="c2e2", backup_destination="azure", backup_status="failure"}[15m]) > 0
count_over_time({instance="proxmox-c2e2", backup_signal="minecraft_backup_health", backup_game="c2e2", backup_destination="azure", backup_status="stale"}[15m]) > 0
absent_over_time({instance="proxmox-c2e2", backup_signal="minecraft_backup_health", backup_game="c2e2", backup_destination="azure"}[30m])
```

The Azure metric alert is a separate cost/runaway guard. It evaluates one hour
of primary OAuth `PutBlock`/`PutBlob` ingress against the parameterized
15 GiB production threshold. It is not a backup-success check.

The account is `Standard_GRS` with private containers, Microsoft Entra OAuth,
shared-key access disabled, and 14-day blob/container soft delete. Its storage
endpoint currently permits public-network access for authenticated writers; an
Azure Private Endpoint is not part of the deployed design.

## Read-only verification

```bash
az storage blob list \
  --account-name stmcbackupsprod \
  --container-name c2e2-backups \
  --auth-mode login \
  --query "[].{name:name,lastModified:properties.lastModified,size:properties.contentLength}" \
  --output table
```

Do not copy or delete production blobs while investigating gaps. Check the
`mc-c2e2-backup-azure` logs in Portainer and the Loki failure/staleness signals.

## 2026-08-23 gap investigation

Read-only blob listing found missing daily archives for June 23-24, July 2-3,
August 12-18, and August 22. Azure ingress also showed no archive-sized writes
during the August gap; the next successful archives landed August 19-21 and
August 23. Azure control-plane activity did not identify a blob deletion or
copy operation. The original host-side failure reason requires retained
Portainer/Loki container logs.
