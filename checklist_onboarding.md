# Onboarding Wiki — Post-Merge Checklist

Admin runbook for shipping the player onboarding wiki (`wiki.negativezone.cc`) and
the automated `setup.ps1` flow after PR #97 merges. Work top-to-bottom; steps 4 and 5
can run in parallel with 2 and 3.

## 1. Approve & merge PR #97

- [ ] Review and **approve** PR #97 (branch protection is the only thing gating it)
- [ ] Merge (squash recommended to keep history tidy)
- [ ] Confirm `main` now contains `docs/`, `docs/assets/setup.ps1`, the storage
      Bicep changes, and both workflows

## 2. Enable GitHub Pages (one-time)

- [ ] Repo → **Settings → Pages**
- [ ] Source: **GitHub Actions**
- [ ] Watch **Actions → Deploy GitHub Pages** run go green on the merge commit
- [ ] Visit the Pages preview URL (e.g. `https://camcast3.github.io/MinecraftInfra/`)
      and confirm the wiki renders

## 3. Wire up the custom domain (one-time)

- [ ] Cloudflare → `negativezone.cc` zone → **DNS → Add record**
  - Type: **CNAME**
  - Name: `wiki`
  - Target: `camcast3.github.io`
  - Proxy status: **DNS only** (grey cloud)
  - TTL: Auto
- [ ] Wait 1–2 min, then repo → **Settings → Pages → Custom domain** should
      auto-verify `wiki.negativezone.cc`
- [ ] Once the cert provisions (5–15 min), tick **Enforce HTTPS**
- [ ] Hit `https://wiki.negativezone.cc/player-onboarding` from a browser

## 4. Deploy the Azure storage change

- [ ] Confirm **Actions → Deploy Azure** runs green on the merge commit
      (the Bicep change flips `allowBlobPublicAccess: true` at the account
      level and adds the `minecraft-modpack` container with
      `publicAccess: 'Blob'`; `minecraft-backups` stays RBAC-only)
- [ ] In the Azure portal, verify `stmcminecraftprod` now lists both
      `minecraft-backups` (Private) and `minecraft-modpack` (Blob)

## 5. Publish the first Prism modpack zip (one-time per version)

On your admin box (Prism + Az CLI installed):

- [ ] `az login`
- [ ] From the repo root:
      `pwsh infra/azure/scripts/publish-prism-pack.ps1 -Version 0.1.0`
- [ ] Verify the manifest is reachable anonymously:
      `curl https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest.json`
- [ ] Note the SHA-256 in `latest.json` — `setup.ps1` will refuse to extract on
      mismatch

## 6. Confirm the auto-release fired

- [ ] **Actions → Release setup script** ran on the merge commit
- [ ] A new tag `setup-v<YYYY.MM.DD>-<sha>` and matching release exist
- [ ] `iwr -useb https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1`
      returns the script (200 OK, not an HTML login page)

## 7. End-to-end smoke test

On a clean Windows machine (or after uninstalling Prism from your own):

- [ ] Run the one-liner:
      `iwr -useb https://github.com/camcast3/MinecraftInfra/releases/latest/download/setup.ps1 | iex`
- [ ] Script installs Java 17 (Temurin) and Prism Launcher via winget
- [ ] Script looks up your UUID via the Mojang API and copies the
      `username + UUID` blob to the clipboard
- [ ] DM yourself the blob → add to `docker/shared/whitelist.json` → push
- [ ] Script downloads `latest.json` + the zip, verifies SHA-256, extracts to
      Prism's `instances/` dir
- [ ] Open Prism → sign in with Microsoft → launch the imported instance
- [ ] In Multiplayer, add `mc.negativezone.cc` and join — you should land
      straight in C2E2

## 8. Tell the players

- [ ] Share `https://wiki.negativezone.cc/player-onboarding` in your group chat
- [ ] Stand by to allowlist `username + UUID` DMs as they come in

---

## When the modpack changes later

1. Update the Prism instance locally with the new mods/configs
2. Bump version and re-run
   `pwsh infra/azure/scripts/publish-prism-pack.ps1 -Version <next>`
3. Existing players: `setup.ps1` checks the `.negativezone-version` marker and
   auto-reinstalls the new version on next run

## When `setup.ps1` itself changes

- Push to `main` → **Release setup script** workflow auto-tags a new
  `setup-v<date>-<sha>` and updates the `latest` release pointer
- No manual tag step required
