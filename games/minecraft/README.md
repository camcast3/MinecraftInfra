# Minecraft

Minecraft owns the `nz` client, C2E2 compose definition, and shared access/config
files under this directory. Compatibility copies preserve:

- the `client/` build and release surface;
- the `docker/proxmox/docker-compose.yml` Portainer GitOps path;
- all `docker/shared/` raw GitHub URLs;
- the existing Compose project/stack identity.

`packwiz/`, `modpack.yml`, and Minecraft-specific Azure publishing scripts have not
moved because active releases embed their current paths.

