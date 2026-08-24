# Admin / operator runbooks

This directory holds runbooks for people who **operate the NegativeZone
server stack** — publishing new modpack versions, rolling back a bad
release, debugging the publish pipeline, etc.

It's intentionally **not** published to [wiki.negativezone.cc](https://wiki.negativezone.cc/):
players don't need to read this, and putting it there would just bury the
player guides under operator noise. Read these files directly in the repo.

## Contents

| File | Topic |
|---|---|
| [`runbook.md`](runbook.md) | Start here: architecture, provisioning, updates, ingress incidents, rollback, and disaster recovery |
| [`backups.md`](backups.md) | Server backup storage, health alerts, verification, and restore safety |
| [`azure-edge.md`](azure-edge.md) | Public game forwarding, Key Vault routes, Tailscale ACLs/DNS, firewall reconciliation, and health |
| [`palworld.md`](palworld.md) | Palworld Portainer deployment, private administration, monitoring, and controlled updates |
| [`multigame-rollout-checklist.md`](multigame-rollout-checklist.md) | Safe pre-production gates and explicit Palworld-then-Windrose live gates |
| [`readiness-palworld.md`](readiness-palworld.md) | Palworld pre-production readiness report and live-only evidence still required |
| [`readiness-windrose.md`](readiness-windrose.md) | Windrose pre-production readiness report, sequenced after Palworld |
| [`publish-runbook.md`](publish-runbook.md) | Cutting a new modpack version: publish workflow, release cadence, rollback, Azure one-time setup |

## Operator flow

Use [`runbook.md`](runbook.md) for the end-to-end decision flow. The other
files are the authoritative detail pages for a specific service or procedure.

## Layout convention

- **Player-facing docs** → `docs/` (published to wiki.negativezone.cc via Jekyll / Just-The-Docs)
- **Operator/admin docs** → `ops/` (repo-local only, plain Markdown, no Jekyll)
- **Architecture / cross-cutting design notes** → top-level `README.md` and per-service READMEs (e.g. `packwiz/README.md`, `docker/azure/README.md`)
- **Game ownership** → `games/`; **platform ownership** → `platform/`; **automation** → `tools/`.
  Existing production paths remain compatibility surfaces until their explicit repoint gates pass.
