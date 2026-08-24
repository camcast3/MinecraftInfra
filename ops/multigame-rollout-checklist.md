# Multi-game rollout checklist

Use
[`Invoke-MultigameRolloutValidation.ps1`](../scripts/Invoke-MultigameRolloutValidation.ps1)
before promoting either dedicated game. The validation order is intentional:
Palworld is the first rollout; Windrose begins only after the Palworld gates
are accepted.

```powershell
pwsh ./scripts/Invoke-MultigameRolloutValidation.ps1

# Optional authenticated, read-only ARM comparison. This never deploys.
pwsh ./scripts/Invoke-MultigameRolloutValidation.ps1 -AzureWhatIf
```

## Safe pre-production gates

- [x] Game/node contracts match Compose, node profiles, edge routes, backup
  targets, pinned images, required secret names, and allowed exposure.
- [x] Palworld and Windrose fixture archives restore into isolated directories;
  checksum, metadata, unsafe paths, wrong-game metadata, and live destinations
  are rejected.
- [x] Actual host backup scripts are exercised as root in a disposable
  container with mocked Docker, NAS, and Azure endpoints. Local/NAS retention,
  Azure 90-day deletion arguments, completion ordering, health markers, and
  interrupted restart recovery are checked.
- [x] Production edge forwarder scripts pass TCP and UDP echo tests on an
  isolated Docker network and reject non-Tailscale backend addresses.
- [x] Backend Compose files publish no host ports; Azure publishes only
  Minecraft TCP 25565, Palworld UDP 8211, and Windrose TCP/UDP 7777.
- [x] Fixture Compose recreation preserves a durable save across update,
  forced recreation, process failure, unhealthy health check, and image
  rollback.
- [x] Palworld and Windrose cloud-init are regenerated, compared with checked-in
  output, contract-linked, checked for public game ports, and validated by
  `cloud-init schema`.
- [x] Azure Bicep compiles locally. Authenticated ARM what-if is optional and
  read-only; its output is evidence, not a deployment approval.

## Palworld live-only gates

- [ ] Provision the dedicated VM from the reviewed node template.
- [ ] Complete short-lived Tailscale and Portainer enrollment.
- [ ] Mount the real NAS and validate the container-scoped Azure writer.
- [ ] Perform one controlled live save/shutdown/restart backup cycle.
- [ ] Confirm a real Palworld client joins through Azure UDP 8211 and that TCP
  8212 remains unreachable publicly.
- [ ] Perform an operator-observed update and Git-revision rollback without
  changing live save data.

Do not start Windrose production rollout until every Palworld live-only gate is
recorded with timestamped operator evidence.

## Windrose live-only gates

- [ ] Provision the dedicated VM from the reviewed node template.
- [ ] Complete short-lived Tailscale and Portainer enrollment.
- [ ] Mount the real NAS and validate the distinct Windrose Azure writer.
- [ ] Perform one controlled cold shutdown and prove `RocksDB_v2` is not copied
  while the process is active.
- [ ] Confirm a real Windrose client joins through both required direct
  connection protocols on Azure port 7777.
- [ ] Perform an operator-observed update and Git-revision rollback without
  changing live save data.

VM creation, real client joins, controlled live shutdowns, live Portainer
changes, and live-save operations are deliberately absent from automated
pre-production validation.
