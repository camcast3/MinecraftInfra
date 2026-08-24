# Palworld production-readiness report

## Pre-production result

**Ready for the Palworld live-gate phase.** The reusable rollout validator
checks the official digest-pinned stack, UDP-only player ingress, private REST
and metrics exposure, contract/secret policy, generated node bootstrap,
isolated backup/restore behavior, retention, failure recovery, Compose
recreation, health failure, and image rollback simulation.

The protocol smoke test executes the exact forwarder and health-check scripts
embedded in the production Azure Compose file. Backup lifecycle tests execute
the production host scripts against fixture data and mocked external systems;
they do not read or write a live save.

## Not yet proven

The following are true live gates, not pre-production passes:

1. Dedicated VM provisioning and first-boot cloud-init completion.
2. Real Tailscale/Portainer enrollment and private REST authentication.
3. A controlled live save, shutdown, cold archive, restart, NAS copy, and Azure
   Cold copy.
4. A real Palworld client join through Azure UDP 8211.
5. A controlled live image update and Git-revision rollback.

Record these in
[`multigame-rollout-checklist.md`](multigame-rollout-checklist.md) before
promoting Palworld or beginning the Windrose live rollout.
