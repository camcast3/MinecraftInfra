# Publish a new modpack version

## Publish

```bash
gh workflow run publish-prism-pack.yml -f version=0.3.1
gh run watch --repo camcast3/MinecraftInfra
```

Or push a tag when you want a named release record:

```bash
git tag modpack/v0.3.1 && git push origin modpack/v0.3.1
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
| Azure login / 403 on blob upload | See [Azure setup](#azure-setup). |

## Azure setup

One-time, admin only. Required for the OIDC login step.

**Federated credential** on the publish managed identity:

| Subject | Purpose |
|---|---|
| `repo:camcast3/MinecraftInfra:environment:production` | Required — the workflow uses `environment: production` |

**Role assignment** — `Storage Blob Data Contributor` scoped to the
`minecraft-modpack` container:

```bash
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee <client-id> \
  --scope "/subscriptions/<sub>/resourceGroups/rg-minecraft-prod/providers/Microsoft.Storage/storageAccounts/stmcminecraftprod/blobServices/default/containers/minecraft-modpack"
```

**Repo secrets** (already configured, shared with `deploy-azure.yml`):
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

**Repo settings** (toggled once):
- Settings → Actions → General → Workflow permissions → "Allow GitHub Actions
  to create and approve pull requests"
- Settings → General → Pull Requests → "Allow auto-merge"
