# Palworld production-readiness report

## Pre-production result

**Ready for live-gate execution.** Automated validation covers:

- the official digest-pinned image and production Compose model;
- no published host ports and a per-stack Tailscale network namespace;
- private authenticated REST with RCON disabled;
- the prior `sudo` plus `no-new-privileges` startup failure and the secure
  one-shot ownership fix;
- deterministic Palworld cloud-init rendering and schema validation;
- no public player-port UFW rule;
- Palworld backup profile and REST quiesce-hook integration;
- the common backup framework dry-run contract; and
- focused workflow linting.

## Live gates

The following require the real environment and are not claimed by CI:

1. Provision the dedicated VM and confirm cloud-init completion.
2. Enroll host and stack Tailscale identities with least-privilege grants.
3. Connect Portainer and deploy the stack with runtime-only secrets.
4. Confirm private UDP 8211 client access and authenticated REST health.
5. Provision the distinct Palworld Azure backup principal/container access,
   mount the NAS, and complete a real save, graceful shutdown, archive,
   restart, NAS copy, and Azure Cold copy.
6. Verify an isolated checksum-enforced restore.
7. Perform one controlled image update and Git-revision rollback.
8. If public player access is required, deliver and validate it in a separate
   narrowly scoped ingress change.
