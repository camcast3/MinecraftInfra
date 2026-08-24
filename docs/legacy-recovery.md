---
layout: default
title: Archived legacy client recovery
nav_exclude: true
---

# Archived legacy client recovery

> **Maintainers only.** The PowerShell client channel is retired. Do not send
> players to these files and do not publish new `setup-v*` or `migrate-v*`
> releases. Production installation and updates use the gated `nz-latest`
> release and `nz setup`, `nz update`, `nz backup`, and `nz migrate`.

The following source files remain at their historical paths only because
already-published immutable releases and pre-nz Prism hooks may fetch them:

- `docs/assets/setup.ps1`
- `docs/assets/update.ps1`
- `docs/assets/backup.ps1`
- `docs/assets/prelaunch-check.ps1`
- `docs/assets/migrate-settings.ps1`
- `docs/assets/latest-version.txt`

They are frozen compatibility/recovery material, not a second release channel.
The old release workflows and legacy E2E workflow have been removed, and new
modpack zips contain no PowerShell hooks.

For any recoverable legacy install, first close Prism and run the production
installer:

```powershell
irm https://github.com/camcast3/MinecraftInfra/releases/download/nz-latest/install.ps1 | iex
```

This installs the verified immutable nz binary, transactionally repairs the
instance, preserves player state, and rewrites Prism hooks. Use an archived
script directly only to diagnose or recover an old immutable install that
cannot reach this path; migrate it to nz immediately afterward.
