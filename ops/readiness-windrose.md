# Windrose production-readiness report

## Pre-production result

**Ready after Palworld completes its live gates.** The reusable rollout
validator checks the digest-pinned Windrose stack, TCP/UDP direct forwarding,
negative public exposure, contract/secret policy, generated node bootstrap,
isolated restore verification, local/NAS/Azure retention behavior, restart
recovery, Compose recreation, unhealthy-state handling, and image rollback
simulation.

The backup fixture runs the production cold-backup script with the Windrose
process probe mocked independently from Docker state. The test proves the
script's completion, retention, metadata, and recovery paths without touching
`RocksDB_v2` or any live save.

## Not yet proven

The following are true live gates, not pre-production passes:

1. Dedicated VM provisioning and first-boot cloud-init completion.
2. Real Tailscale/Portainer enrollment.
3. An operator-confirmed cold shutdown with no active
   `WindroseServer-Linux-Shipping` process before copying `RocksDB_v2`.
4. Real client joins through Azure TCP and UDP port 7777.
5. A controlled live image update and Git-revision rollback.

Do not treat fixture protocol echoes as a real Windrose client join. Complete
and record Palworld first, then use
[`multigame-rollout-checklist.md`](multigame-rollout-checklist.md) for Windrose.
