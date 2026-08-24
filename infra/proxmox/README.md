# Proxmox provisioning

## Minecraft VM

`cloud-init.yaml` remains the vendor-data configuration for the existing
`mc-proxmox` VM. Keep using its documented Proxmox Cloud-Init settings and
`mcsvc` account; the reusable game-node template does not replace or alter that
VM.

## Palworld and Windrose VMs

Use [`game-node/README.md`](game-node/README.md) to render separate Debian 13
vendor-data files for the Palworld and Windrose VMs. The profiles share the
same hardened Docker host provisioning while retaining distinct service users,
Tailscale names, maintenance windows, and storage roots.

The Windrose Portainer GitOps stack is documented in
[`../../docker/windrose/README.md`](../../docker/windrose/README.md).
