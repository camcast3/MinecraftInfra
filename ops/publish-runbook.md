# Publish a new modpack version

## TL;DR

`gh workflow run publish-prism-pack.yml -f version=0.4.2` (or push a
`modpack/v0.4.2` tag). The workflow builds the client zip from `packwiz/`,
uploads it to Azure blob, atomically rewrites `docker/proxmox/docker-compose.yml`
(`PACKWIZ_URL` + `MOTD`) and `docker/azure/velocity/velocity.toml.tmpl`
(fallback `motd`) and `modpack.yml`, opens a publish PR with auto-merge.
Portainer GitOps then redeploys C2E2 within ~5 min. **Server + client +
fallback proxy MOTD move atomically.**

End-to-end the only manual step is triggering the workflow. Internal
sequencing, locking, error handling, etc. live in the script's own
comments — read those when you need to debug the pipeline, not this doc.

---

## Release cadence

Versioning follows SemVer-ish rules tuned to the client/server-coupling reality of a Forge modpack:

| Bump | Example | Semantics | Server impact |
|---|---|---|---|
| **PATCH** | `0.4.1` → `0.4.2` | Client-only change. Config tweaks, single-mod version bumps, performance tuning, prelaunch/postexit script fixes. No new mods, no server-side mod versions changed. | Forge container **redeploys** (MOTD version bump) — see migration note below. ~30 s of "Server unavailable" for connecting players. |
| **MINOR** | `0.4.x` → `0.5.0` | Client + server need to be in sync. New mod added/removed, major mod version bump, anything that would FML-handshake-kick existing clients. | Forge container redeploys with new PACKWIZ_URL + MOTD. Same ~30 s window. |
| **MAJOR** | `0.x.y` → `1.0.0` | Stability milestone: cut after a **full calendar month** with zero management-caused downtime (publish bugs, prelaunch bugs, update.ps1 corruption, etc.). Not a content gate. | Same as MINOR. |

Whichever bump you cut, the publish workflow is identical — the cadence
distinction is purely about **what changed in `packwiz/`** and the player
communication that should accompany it.

### Migration note — why PATCH currently redeploys the server

In theory, PATCH (client-only) releases shouldn't need to touch the Forge
container at all. Today they still do, because the **MOTD version string
in the server list** is the only update signal that **existing v0.4.x
players** (installed before `prelaunch-check.ps1` shipped) can see — their
instances have no launch-time check, so the MOTD is what tells them "go
re-run the update one-liner". Until everyone has migrated onto a
prelaunch-equipped instance, we keep paying the redeploy cost on PATCH.

To revisit once telemetry / opt-in confirms migration:

- **Option A — drop MOTD versioning entirely.** Once `prelaunch-check.ps1`
  is universal, the MOTD doesn't need to carry the version; the hard
  block does that job better. PATCH would become a pure client release
  (PR merge, no compose change, no redeploy).
- **Option B — MiniMOTD plugin on Velocity.** Lets us keep the
  version-in-MOTD UX without the Forge container restart. The version
  string is rendered at the proxy and can be updated via a `reload`
  command instead of a redeploy.

Both are tracked as follow-ups; neither is urgent until the migration
window closes.

---

## Publish

```bash
gh workflow run publish-prism-pack.yml -f version=0.4.2
gh run watch --repo camcast3/MinecraftInfra
```

Or push a tag when you want a named release record:

```bash
git tag modpack/v0.4.2 && git push origin modpack/v0.4.2
```

Portainer redeploys C2E2 within ~5 min of the auto-merge.

## Rollback

Revert the publish commit on `main`:

```bash
git revert <publish-commit-sha>
git push origin main
```

Portainer redeploys within ~5 min. Then re-point `latest.json` at the
last-known-good version (values from `modpack.yml` history):

```bash
az storage blob upload \
  --account-name stmcminecraftprod \
  --container-name minecraft-modpack \
  --name latest.json \
  --data '{"version":"0.3.0","url":"https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/c2e2-v0.3.0.zip","sha256":"<sha256>"}' \
  --overwrite --auth-mode login
```

Each publish uploads a uniquely-named blob, so old zips stay intact —
they're inert once `latest.json` no longer points at them.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No-op publish" summary, workflow exits | `modpack.yml` is already at that version. Bump the version. |
| Version rejected — unsafe characters | Use only `[A-Za-z0-9.+_-]`. |
| Stuck on "Waiting for concurrency group" | Another publish is in-flight; wait for it. |
| PR merged but C2E2 didn't redeploy | Wait 5 min for the Portainer GitOps poll, then check the C2E2 stack logs in Portainer. |
| `gh pr create` says PR already exists | A previous run left a `modpack/v<ver>` branch. Delete the branch + close the PR, then re-run. |
| Azure login / 403 on blob upload | Federated credential or role assignment on the publish identity is missing — ping an infra admin. |
