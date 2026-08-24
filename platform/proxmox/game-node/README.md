# Debian 13 Proxmox game-node template

This template provisions separate Palworld and Windrose Docker hosts without
changing the existing Minecraft VM configuration in
[`platform/proxmox/minecraft/cloud-init.yaml`](https://github.com/camcast3/MinecraftInfra/blob/main/platform/proxmox/minecraft/cloud-init.yaml).

## What the common template installs

- Docker CE and the Compose/Buildx plugins from Docker's Debian repository
- QEMU guest agent
- Host-level Tailscale for administration
- UFW with inbound traffic denied by default
- Daily unattended security upgrades with a staggered reboot time
- Per-game data, config, stack-Tailscale, backup, monitoring/Alloy, and
  Portainer Edge Agent directories
- Host systemd backup/health timers, rclone, checksum metadata, and an
  interrupted-run recovery service, plus an isolated restore verifier
- A restricted sudo policy for Docker and service inspection

Tailscale authentication and Portainer enrollment are deliberately post-boot
steps so auth keys and Edge credentials never enter Git.

The backup timer is installed immediately but its service has a
`ConditionPathExists` gate on `/etc/game-backup/rclone.conf`. Configure the NAS
mount and copy the root-only rclone example into place before the first run.
Use only the matching game's container-scoped Azure writer identity. See
[`../../../ops/backups.md`](../../../ops/backups.md) for first-run, alert, and
restore verification.

## Profiles

<!-- markdownlint-disable MD013 -->

| Profile | Proxmox Cloud-Init user | Tailscale hostname | Storage root | Reboot |
| --- | --- | --- | --- | --- |
| `palworld` | `palworldsvc` | `palworld-proxmox` | `/data/palworld` | 03:30 |
| `windrose` | `windrosesvc` | `windrose-proxmox` | `/data/windrose` | 04:00 |

<!-- markdownlint-enable MD013 -->

The profile JSON files are the per-game overlays. Before rendering, edit each
profile's `managementCidrs` to the smallest LAN/admin source ranges that need
direct OpenSSH access. CIDRs are validated by the renderer. Tailscale
administration remains available independently on `tailscale0`.

Profiles can declare intentional public game ports, but both current game
nodes allow none: the Azure edge owns Palworld 8211/udp and Windrose
7777/tcp+udp. The renderer validates any future entries and emits matching UFW
rules. Docker-published ports still bypass some UFW paths, so each backend
Compose stack must publish no broader surface.

## Render vendor data

From the repository root:

```powershell
pwsh .\infra\proxmox\game-node\Render-CloudInit.ps1 `
  -Profile palworld `
  -OutputPath .\infra\proxmox\game-node\generated\palworld-cloud-init.yaml

pwsh .\infra\proxmox\game-node\Render-CloudInit.ps1 `
  -Profile windrose `
  -OutputPath .\infra\proxmox\game-node\generated\windrose-cloud-init.yaml
```

The checked-in generated files are ready to upload. Re-render them after any
template or profile change.

## Create each Proxmox VM

Build one Debian 13 generic-cloud template, following the commands at the top
of `../cloud-init.yaml`. Clone it once per game, then configure:

```text
CPU type:       host
QEMU agent:     enabled
Cloud-Init IP:  DHCP or a reserved/static address
Cloud-Init user and SSH key: use the profile table above
```

Attach the matching rendered file as **vendor data** so the Proxmox-generated
user data can still inject the user and SSH public key:

```bash
cp palworld-cloud-init.yaml /var/lib/vz/snippets/
qm set <palworld-vmid> --cicustom "vendor=local:snippets/palworld-cloud-init.yaml"

cp windrose-cloud-init.yaml /var/lib/vz/snippets/
qm set <windrose-vmid> --cicustom "vendor=local:snippets/windrose-cloud-init.yaml"
```

Use `qm cloudinit dump <vmid> vendor` to confirm the attached content before
the first boot.

### CPU and memory guidance

Use `--cpu host` for game-server VMs; emulated compatibility CPU models omit
instruction-set features and cost single-thread performance. Prefer real
physical cores over aggressive vCPU overcommit, and keep the busiest game
servers on different host cores if contention appears. `--balloon 0` is
recommended when predictable game-server memory is more important than memory
overcommit. CPU-host VMs can only live-migrate to hosts with compatible CPUs.

Example starting points, to be adjusted from observed load:

```bash
qm set <palworld-vmid> --cores 8 --memory 24576 --balloon 0 --cpu host
qm set <windrose-vmid> --cores 6 --memory 16384 --balloon 0 --cpu host
```

## First boot

Use the Proxmox console or one of the profile's management CIDRs:

```bash
ssh -p 7822 <profile-user>@<lan-ip>
sudo cloud-init status --wait
sudo systemctl status qemu-guest-agent docker tailscaled
sudo ufw status verbose
```

Enroll host-level Tailscale using a short-lived, preauthorized key:

```bash
sudo tailscale up --ssh --hostname=<profile-tailscale-hostname> --authkey=<auth-key>
tailscale status
```

The template permits Tailscale SSH on port 22 and regular OpenSSH on the
profile's configured port over `tailscale0`. Only profile-declared game ports
are opened by UFW.

## Portainer Edge Agent

In the central Portainer instance:

1. Open **Environments → Add environment → Docker Standalone → Edge Agent
   Standard**.
2. Create a distinct environment named `palworld-proxmox` or
   `windrose-proxmox`.
3. Copy Portainer's generated command and run it on the matching VM.
4. In that command, use the pre-created host directory for Edge Agent state:
   `-v /data/<game>/portainer-edge-agent:/data`.
5. Confirm that the environment is connected before deploying its game stack.

The Edge Agent initiates its connection outbound, so no inbound Portainer port
is required.

Deploy each Git stack from its `docker/<game>/docker-compose.yml` path. Player
traffic stays inside the per-stack Tailscale network namespace; neither stack
publishes a host game port.

> Docker-published container ports can bypass host UFW rules. Do not publish a
> game port until its intended exposure is defined; bind it to the appropriate
> LAN/Tailscale address or add an explicit `DOCKER-USER` policy.
