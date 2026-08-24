# Game and node contracts

These JSON files describe where each game instance runs and the operational
requirements that must be satisfied before it is treated as production. They
reference the existing deployment and provisioning files; they do not replace
or relocate those files.

- `nodes/` describes the Azure proxy VM, the existing Minecraft Proxmox VM,
  and the Palworld and Windrose game nodes.
- `games/` describes the Velocity and C2E2 production instances plus the
  implemented, pre-promotion Palworld and Windrose stacks.
- `node-contract.schema.json` and `game-contract.schema.json` document the
  contract formats.

Production image references must contain both a non-empty tag and a
`sha256:<64 hex characters>` digest. Planned instances may leave the image
reference null, but their policy must still require a tag and digest before
promotion to production.

Port exposure is declared per node. `ports` describes the game container's
local or tailnet listener; optional `edgeRoutes` describes player traffic that
the Azure edge publishes and forwards to that listener. Public bindings may
only serve players; RCON, metrics, SSH, Portainer, and other administrative
endpoints must remain private. Public port uniqueness is enforced on the node
that actually publishes each route.

Contracts contain secret names only. Secret values continue to come from
Azure Key Vault or Portainer's environment UI.

Run validation from the repository root:

```powershell
pwsh .\scripts\Validate-GameContracts.ps1
pwsh .\scripts\tests\Test-GameContracts.ps1
```
