# Azure and C2E2 backup operations

## Storage isolation

Player distribution remains in the public `minecraft-modpack` container in
`stmcminecraftprod`. Server archives move to the dedicated private account:

- Account: `stmcbackupsprod`
- C2E2 container: `c2e2-backups`
- Authentication: Microsoft Entra OAuth only
- Authorization: the C2E2 service principal has `Storage Blob Data Contributor`
  only on `c2e2-backups`
- Protection: anonymous and shared-key access are disabled; blob and container
  soft delete are retained for 14 days

Palworld and Windrose have distinct, empty writer parameters. Their containers
are not deployed until their own principal IDs are deliberately added to the
production parameters; neither workload may reuse the C2E2 identity.

Changing an existing writer fails closed. The role-assignment resource ID is
stable per container, so remove the old assignment explicitly before replacing
its principal.

## C2E2 migration

Historical blobs under
`stmcminecraftprod/minecraft-backups/c2e2/` are intentionally left untouched.
This change affects new uploads only.

Before allowing Portainer to redeploy the C2E2 stack:

1. Review the Azure what-if and deploy the Bicep changes through the normal
   production workflow.
2. Confirm `stmcbackupsprod/c2e2-backups` exists and the C2E2 role assignment is
   present.
3. Set `BACKUP_STORAGE_ACCOUNT=stmcbackupsprod` in the Portainer stack
   environment. Keep the existing C2E2 tenant, client ID, and client secret.
4. Redeploy the stack and run a manual Azure backup.
5. Confirm the archive is visible with a read-only listing:

   ```bash
   az storage blob list \
     --account-name stmcbackupsprod \
     --container-name c2e2-backups \
     --auth-mode login \
     --query "[].{name:name,lastModified:properties.lastModified,size:properties.contentLength}" \
     --output table
   ```

Do not copy or delete production blobs during verification.

## Backup health signals

`backup-azure` writes a persistent success timestamp and emits one structured
result line. The non-networked `backup-health` sidecar checks freshness every
15 minutes and emits only state transitions. A marker is stale after 36 hours.

```text
minecraft_backup_result game=c2e2 destination=azure status=success
minecraft_backup_result game=c2e2 destination=azure status=failure exit_code=1
minecraft_backup_health game=c2e2 destination=azure status=healthy age_seconds=300
minecraft_backup_health game=c2e2 destination=azure status=stale age_seconds=129900
```

Promtail extracts `backup_signal`, `backup_game`, `backup_destination`, and
`backup_status`. Recommended Loki alerts:

```logql
count_over_time({instance="proxmox-c2e2", backup_signal="minecraft_backup_result", backup_game="c2e2", backup_destination="azure", backup_status="failure"}[15m]) > 0
count_over_time({instance="proxmox-c2e2", backup_signal="minecraft_backup_health", backup_game="c2e2", backup_destination="azure", backup_status="stale"}[15m]) > 0
absent_over_time({instance="proxmox-c2e2", backup_signal="minecraft_backup_health", backup_game="c2e2", backup_destination="azure"}[30m])
```

The Azure metric alert is a separate runaway-write and cost guard. It evaluates
one hour of primary OAuth `PutBlock`/`PutBlob` ingress against the parameterized
15 GiB production threshold; it does not prove that backups succeeded.
