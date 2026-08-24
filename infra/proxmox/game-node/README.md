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

Tailscale authentication, Portainer enrollment, rclone credentials, and
application-specific backup hooks are deliberately post-boot steps. Secrets
must not be included in a profile or rendered vendor data.

## Profile schema

Profiles are intentionally not committed with this framework. Create a local
JSON file with the following fields:

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
  -ProfilePath .\path\to\profile.json `
  -OutputPath .\build\example-game-cloud-init.yaml
```

The renderer validates identifiers, CIDRs, ports, source paths, and backup
settings, embeds the versioned scripts and systemd units, rejects unresolved
tokens, and writes UTF-8 without a BOM. Generated vendor data is not tracked.

Attach the output to a new Debian 13 VM as Proxmox vendor data. Use the
Proxmox Cloud-Init UI for the matching service user and administrator SSH key:

```bash
cp example-game-cloud-init.yaml /var/lib/vz/snippets/
qm set <vmid> --cicustom "vendor=local:snippets/example-game-cloud-init.yaml"
qm cloudinit dump <vmid> vendor
```

CPU type `host`, QEMU agent enabled, and ballooning disabled are sensible
starting points for latency-sensitive game nodes. Size CPU, memory, and
storage from observed application load.

## Shared `birdo` operator account

Every rendered game node creates `birdo` with passwordless sudo. The committed
vendor data intentionally leaves the password locked. After the node is
reachable through an SSH host alias, copy the existing Palworld password hash
over encrypted SSH:

```powershell
.\infra\proxmox\game-node\Set-GameNodeOperatorPassword.ps1 `
  -SourceHost palworld `
  -TargetHost <new-node-ssh-alias>
```

The helper never prints or writes the hash locally. Password authentication is
enabled only for `birdo`; UFW still limits SSH to configured management CIDRs
and Tailscale.

## Backup lifecycle

`game-backup@<slug>.timer` is installed by rendered vendor data, but its
service has a `ConditionPathExists` gate on
`/etc/game-backup/rclone.conf`. Until a root-owned rclone configuration is
installed, scheduled backups do not run.

This mirrors Minecraft's 3-2-1 destinations and retention—14 days local,
7 days on NAS, and 90 days in Azure Cold—but runs as a host systemd service,
not a backup container. One application-consistent archive is created and
replicated to all three destinations, avoiding three separate game shutdowns.
The script uses the host Docker CLI only to quiesce and restart the named game
container; it never mounts the Docker socket into another container.

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
