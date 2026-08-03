# Vendored upstream: JPVenson/Jellyfin.Pgsql

This directory is an UNMODIFIED vendor drop of the `Jellyfin.Plugin.Pgsql` project from the
upstream [JPVenson/Jellyfin.Pgsql](https://github.com/JPVenson/Jellyfin.Pgsql) repository. Task
`pgsql-plugin-bundle` (ROI UNSTICK item 2) tracks upstream releases — it never forks or
reimplements the provider logic.

- **Upstream repo:** https://github.com/JPVenson/Jellyfin.Pgsql
- **Pinned tag:** `10.11.11-1`
- **Pinned commit SHA:** `f410c8a874f5298ac9f244145457e9a65ea757e5`
- **Vendored path upstream:** `Jellyfin.Plugin.Pgsql/` (project renamed on vendor to
  `Jellyfin.Pgsql/Jellyfin.Pgsql.csproj` to match this fork's build-path convention — the
  `RootNamespace`/`Jellyfin.Plugin.Pgsql` C# namespace and ALL source files are byte-for-byte
  identical to upstream; only the containing folder name and `.csproj` filename changed).
- **Runtime plugin GUID (`Plugin.Id`, `Jellyfin.Plugin.Pgsql.Plugin`):** `27e7ad18-ea71-4b19-b1a9-6e4c2e4d5e18` —
  this is the identity Jellyfin's plugin manager keys on; `meta.json` (baked alongside the DLL, see
  below) MUST keep this GUID stable across ref bumps so Jellyfin treats a bump as a plugin *update*,
  never a new plugin. (Upstream's own top-level `manifest.json` GUID `ecb9be01-627b-4904-a28e-8d0d5b481272`
  is a *different*, catalogue-listing identity used only by upstream's own plugin-repository page —
  not the runtime plugin id — do not confuse the two.)
- **Why this tag:** `10.11.11-1` is upstream's release built against Jellyfin `10.11.11`, matching
  this fork's current base (`base-bump-execute` bumped to v10.11.11 / `1fbd873929`).
- **DSN / connection config — already env-var driven upstream, NOT a hardcoded DSN:** the provider
  reads `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD`
  from the process environment (`Configuration/PluginConfiguration.cs`), with `POSTGRES_PASSWORD`
  required (no insecure default). This is exactly the seam the per-color chart values need: set
  `POSTGRES_DB=jellyfin_dev` / `jellyfin_prod` (and the other four vars) per color in the
  HelmRelease values — this jellyfin repo does not, and should not, hardcode any of them. Wiring
  those env vars into the chart values is **owned by `phantom-library`'s Postgres P4 Stage-A** (not
  this task) — see the cross-dep note on task `pgsql-plugin-bundle` in `PLAN.md`.

## Bumping the ref
A ref bump is OPERATOR-VISIBLE (per ROI). To bump: pick the new upstream tag, record its tag+SHA
here, re-vendor `Jellyfin.Plugin.Pgsql/` verbatim from that tag over this directory (keeping the
`Jellyfin.Pgsql/Jellyfin.Pgsql.csproj` rename), rebuild, and re-bake into the image.

## Build
```
dotnet build Jellyfin.Pgsql/Jellyfin.Pgsql.csproj -c Release
```
