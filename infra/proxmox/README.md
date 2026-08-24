# Proxmox provisioning

## Existing Minecraft VM

`cloud-init.yaml` remains the vendor-data configuration for the existing
Minecraft VM. The reusable game-node framework does not replace, render, or
alter that file.

## Reusable game nodes

[`game-node/README.md`](game-node/README.md) documents the inert Debian 13
template, profile renderer, and host-level backup framework for future
dedicated Docker game nodes. No production profile or generated vendor data is
included; provisioning requires an explicit local profile, render, and
Proxmox attachment.
