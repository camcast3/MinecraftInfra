# Debian 13 Proxmox game-node framework

This directory contains an inert, reusable Cloud-Init renderer and host-level
backup framework for dedicated Docker game nodes. Merging these files does not
provision a VM, attach vendor data, enable a timer, or modify an existing host.

## What the template installs

- Docker CE with the Compose and Buildx plugins
- QEMU guest agent and host-level Tailscale
- UFW with inbound traffic denied by default
- Daily unattended security upgrades
- Per-node data, backup, monitoring, and Portainer Edge Agent directories
- Application-consistent backup, health, interrupted-run recovery, and
  isolated restore tools

Tailscale authentication, Portainer enrollment, and rclone credentials are
deliberately post-boot steps. Secrets must not be included in a profile or
rendered vendor data. The versioned game hooks contain no credentials. Palworld expands its runtime
password only inside the game container; Windrose confirms a cold stop before
the framework can archive `RocksDB_v2`.

## Profile schema

The production Palworld and Windrose profiles are committed under `profiles/`.
Other profiles may be supplied locally with the following fields:

```json
{
  "displayName": "Example game",
  "gameSlug": "example-game",
  "serviceUser": "examplesvc",
  "tailscaleHostname": "example-game-node",
  "dataRoot": "/data/example-game",
  "azureBackupContainer": "example-game-backups",
  "containerName": "example-game-server",
  "backupSources": ["data", "config"],
  "backupConsistency": "confirmed-cold-stop",
  "backupStopMode": "container-stop",
  "sshPort": 7822,
  "rebootTime": "03:30",
  "managementCidrs": ["192.0.2.0/24"],
  "publicPorts": []
}
```

`backupStopMode` can be `container-stop` or `hook`. Hook mode invokes the
root-owned executable at
`/usr/local/libexec/game-backup/<gameSlug>` with the container name and stop
timeout. The hook must quiesce the application and leave the container
stopped; the common framework verifies that state before archiving.

Profiles may declare public ports as objects containing `port`, `protocol`,
and `comment`. Keep the list empty when traffic arrives over a private
overlay network. Docker-published ports can bypass some UFW paths, so Compose
stacks must independently limit their published surface.

## Render vendor data

From the repository root:

```powershell
pwsh .\infra\proxmox\game-node\Render-CloudInit.ps1 `
  -ProfilePath .\infra\proxmox\game-node\profiles\palworld.json `
  -OutputPath .\infra\proxmox\game-node\generated\palworld-cloud-init.yaml
```

The renderer validates identifiers, CIDRs, ports, source paths, and backup
settings, embeds the versioned scripts and systemd units, rejects unresolved
tokens, and writes UTF-8 without a BOM. The checked-in Palworld and Windrose vendor data are equality-tested against
their profiles and template.

Attach the output to a new Debian 13 VM as Proxmox vendor data. Use the
Proxmox Cloud-Init UI for the matching service user and administrator SSH key:

```bash
cp palworld-cloud-init.yaml /var/lib/vz/snippets/
qm set <vmid> --cicustom "vendor=local:snippets/palworld-cloud-init.yaml"
qm cloudinit dump <vmid> vendor
```

CPU type `host`, QEMU agent enabled, and ballooning disabled are sensible
starting points for latency-sensitive game nodes. Size CPU, memory, and
storage from observed application load.

## Backup lifecycle

`game-backup@<slug>.timer` is installed by rendered vendor data, but its
service has a `ConditionPathExists` gate on
`/etc/game-backup/rclone.conf`. Until a root-owned rclone configuration is
installed, scheduled backups do not run.

Each run:

1. Acquires a per-node lock and records restart recovery state.
2. Disables the container restart policy and performs the configured cold stop
   or quiesce hook.
3. Refuses to archive until the container is stopped.
4. Produces an archive, SHA-256 file, and completion metadata as one triplet.
5. Restarts the container and waits for Docker health.
6. Publishes independently to local disk, a mounted NAS, and Azure Blob via
   rclone, then applies per-tier retention.

Copy `backup/rclone.conf.example` to `/etc/game-backup/rclone.conf`, replace
its placeholders with a node-scoped writer identity, set ownership to root,
and mode to `0600`. Verify the NAS is a real mount point before enabling a
production schedule.

Restore operations require all three files, verify metadata and checksum,
reject unsafe archive entries, and refuse destinations under `/data`.
Restore into an isolated path first:

```bash
sudo game-restore --game example-game \
  --archive /path/example-game-YYYYMMDDTHHMMSSZ.tar.gz \
  --destination /srv/restore-verification/example-game
```

Promoting restored data into a live stack remains an explicit,
application-specific operation.
