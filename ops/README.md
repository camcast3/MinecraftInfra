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
| [`publish-runbook.md`](publish-runbook.md) | Cutting a new modpack version: publish workflow, release cadence, rollback, Azure one-time setup |

## Layout convention

- **Player-facing docs** → `docs/` (published to wiki.negativezone.cc via Jekyll / Just-The-Docs)
- **Operator/admin docs** → `ops/` (repo-local only, plain Markdown, no Jekyll)
- **Architecture / cross-cutting design notes** → top-level `README.md` and per-service READMEs (e.g. `packwiz/README.md`, `docker/azure/README.md`)
