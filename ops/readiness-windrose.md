# Windrose production-readiness report

## Pre-production result

**Ready for live-gate execution.** Automated validation covers:

- the official digest-pinned amd64 native Linux image and ELF payload;
- image metadata exposing only TCP and UDP 7777, with no Wine or 7778;
- production Compose configuration with no host-published ports;
- direct-connection configuration bootstrap and controlled reseeding;
- `SIGTERM` propagation through the launcher;
- deterministic Windrose cloud-init rendering and schema validation;
- no public player-port UFW rule;
- the confirmed-cold-stop hook and backup framework dry-run contract; and
- Compose persistence, image-update, unhealthy-state, and rollback simulation.

## Live gates

The following require the real environment and are not claimed by CI:

1. Provision the dedicated VM and confirm cloud-init completion.
2. Enroll host and stack Tailscale identities with least-privilege grants.
3. Connect Portainer and deploy the stack with runtime-only secrets.
4. Confirm real client access over both TCP and UDP 7777.
5. Observe a graceful production shutdown and confirm no active
   `WindroseServer-Linux-Shipping` process before copying `RocksDB_v2`.
6. Complete local, NAS, and Azure Cold backup writes and an isolated restore.
7. Perform one controlled image update and Git-revision rollback.

Fixture listeners and mocked backups are not substitutes for a real client
join, real shutdown, real offsite write, or observed rollback.
