# MinecraftInfra

This repository is migrating incrementally to game-server-centric ownership:

- [`games/`](games/README.md) owns game-specific clients, stacks, and shared game data.
- [`platform/`](platform/README.md) owns infrastructure, edge routing, node provisioning,
  backups, and contracts.
- [`tools/`](tools/README.md) owns repository automation and validation entry points.

Production consumers still use the established `docker/`, `infra/`, `client/`, and
`contracts/` paths. Those paths are compatibility surfaces until their documented
repoint gates are complete; no Portainer stack is repointed by this migration.

Operators should start with [`ops/runbook.md`](ops/runbook.md). Player-facing
Minecraft instructions remain under [`docs/`](docs/index.md).

Run the layout check before committing:

```powershell
pwsh ./tools/layout/Sync-CompatibilityPaths.ps1
pwsh ./tools/layout/Test-RepositoryLayout.ps1
```
