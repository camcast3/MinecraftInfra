# Platform

Cross-game infrastructure belongs here:

- `azure/iac/` — Azure Bicep, with resource names and deployment parameters unchanged;
- `azure/edge/` — public layer-4 forwarding and secret refresh;
- `proxmox/game-node/` — reusable node provisioning and backup/restore tooling;
- `contracts/` — declarative game/node policy.

The existing `infra/`, `docker/azure/`, and `contracts/` paths remain generated
compatibility surfaces for current workflows and production consumers.

