# Modpack migration gate

The authoritative C2E2 pack remains at `packwiz/` with release metadata in the
root-level `modpack.yml`.

Move it here only after:

1. old and new raw GitHub URLs are published together;
2. the server and all supported `nz` clients accept the new URL;
3. an immutable release has completed a rollback/upgrade soak;
4. the old URL has a documented retirement date.

