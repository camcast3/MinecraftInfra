# Publish a new modpack version

## TL;DR

`gh workflow run publish-prism-pack.yml -f version=0.4.2` (or push a
`modpack/v0.4.2` tag). The workflow builds the client zip from `packwiz/`,
uploads immutable versioned zip + manifest candidates to Azure blob, rewrites `docker/proxmox/docker-compose.yml`
(`PACKWIZ_URL` + `MOTD`) and `docker/azure/velocity/velocity.toml.tmpl`
(fallback `motd`) and `modpack.yml`, and opens a publish PR with auto-merge. Portainer GitOps
then redeploys C2E2 within ~5 min. A separate promotion workflow waits for the
public server to advertise the new version before moving `latest.json` and
`latest-version.txt`.

End-to-end the only manual step is triggering the workflow. Internal
sequencing, locking, error handling, etc. live in the script's own
comments — read those when you need to debug the pipeline, not this doc.

---

## Release cadence

Versioning follows SemVer-ish rules tuned to the client/server-coupling reality of a Forge modpack:

| Bump | Example | Semantics | Server impact |
|---|---|---|---|
| **PATCH** | `0.4.1` → `0.4.2` | Client-only change. Config tweaks, single-mod version bumps, performance tuning, or nz hook fixes. No new mods, no server-side mod versions changed. | Forge container **redeploys** (MOTD version bump). ~30 s of "Server unavailable" for connecting players. |
| **MINOR** | `0.4.x` → `0.5.0` | Client + server need to be in sync. New mod added/removed, major mod version bump, anything that would FML-handshake-kick existing clients. | Forge container redeploys with new PACKWIZ_URL + MOTD. Same ~30 s window. |
| **MAJOR** | `0.x.y` → `1.0.0` | Stability milestone: cut after a **full calendar month** with zero management-caused downtime (publish bugs, launch-check bugs, client corruption, etc.). Not a content gate. | Same as MINOR. |

Whichever bump you cut, the publish workflow is identical — the cadence
distinction is purely about **what changed in `packwiz/`** and the player
communication that should accompany it.

PATCH releases currently redeploy the backend because the publish transaction
keeps the server MOTD, packwiz SHA, and client manifest on one auditable
version. The nz launch check is the authoritative player update signal.

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

Portainer redeploys C2E2 within ~5 min of the auto-merge. Stable client
pointers remain on the prior release until the public Minecraft status/MOTD
gate passes.

## Rollback

Revert the publish commit on `main`:

```bash
git revert <publish-commit-sha>
git push origin main
```

Portainer redeploys within ~5 min. After the direct backend health check passes,
promote the complete immutable manifest with the explicit downgrade opt-in:

```powershell
./infra/azure/scripts/promote-prism-pack.ps1 -AllowDowngrade
```

The script downloads the committed immutable manifest and zip, verifies the
full compatibility block, source commit, size, and SHA-256, then uploads a
complete `latest.json` with `allowDowngrade: true`. Never hand-build a reduced
rollback manifest: current clients reject missing compatibility metadata and
reject a version rollback without the explicit downgrade flag.

Each publish uploads uniquely named immutable assets, so old zips stay intact.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No-op publish" summary, workflow exits | `modpack.yml` is already at that version. Bump the version. |
| Version rejected — unsafe characters | Use only `[A-Za-z0-9.+_-]`. |
| Stuck on "Waiting for concurrency group" | Another publish is in-flight; wait for it. |
| PR merged but C2E2 didn't redeploy | Wait 5 min for the Portainer GitOps poll, then check the C2E2 stack logs in Portainer. |
| Promotion workflow times out | The server never advertised the committed version. Stable pointers remain unchanged; fix/redeploy the server, then re-run `promote-prism-pack.yml`. |
| `gh pr create` says PR already exists | A previous run left a `modpack/v<ver>` branch. Delete the branch + close the PR, then re-run. |
| Azure login / 403 on blob upload | Federated credential or role assignment on the publish identity is missing — ping an infra admin. |
