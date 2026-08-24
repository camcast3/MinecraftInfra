# Azure platform

`iac/` owns the Azure templates and `edge/` owns the deployed forwarding stack.
Compatibility copies remain under `infra/azure/` and `docker/azure/`. The deployment
continues to use `rg-minecraft-prod`, `vm-minecraft-prod`, and all existing resource
names; this migration does not recreate or rename Azure resources.

Minecraft pack publishing scripts remain under `infra/azure/scripts/` until their
released paths and workflow callers can migrate independently.

