# Palworld production-readiness report

## Pre-production result

**Ready for live-gate execution.** Automated validation covers:

- the reviewed, digest-pinned `thijsvanloef/palworld-server-docker` image and
  production Compose model;
- source-restricted LAN publication of UDP 8211 and a per-stack Tailscale
  network namespace;
- private authenticated REST with RCON disabled;
- non-root game execution through the image's `gosu` entrypoint under
  `no-new-privileges`;
- deterministic Palworld cloud-init rendering and schema validation;
- no unrestricted public player-port rule;
- Palworld backup profile and REST quiesce-hook integration;
- the common backup framework dry-run contract; and
- focused workflow linting.

## Live gates

The following require the real environment and are not claimed by CI:

1. Provision the dedicated VM and confirm cloud-init completion.
2. Enroll host and stack Tailscale identities with least-privilege grants.
3. Deploy the Compose stack with runtime-only secrets; Portainer is optional.
4. Confirm UDP 8211 client access from both approved LAN VLANs, denial from an
   unapproved VLAN, and authenticated REST health over Tailscale.
5. Provision the distinct Palworld Azure backup principal/container access,
   mount the NAS, and complete a real save, graceful shutdown, archive,
   restart, NAS copy, and Azure Cold copy.
6. Verify an isolated checksum-enforced restore.
7. Perform one controlled image update and Git-revision rollback.
8. If public player access is required, deliver and validate it in a separate
   narrowly scoped ingress change.
