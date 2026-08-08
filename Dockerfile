# syntax=docker/dockerfile:1
#
# Patched-Jellyfin container image — task `jellyfin:container-image` (ROI Priority 3, KEYSTONE).
#
# WHAT THIS BUILDS
#   A deployable image of the ADDITIVE-patched Jellyfin fork:
#     * base Jellyfin v10.11.11 (base SHA 1fbd873929, bumped from v10.11.9/e83a7e62f2 by task
#       `base-bump-execute`, ROI Priority 4 — enabling floor for jellyfin-plugin-mysql), and
#     * the additive channel-refresh + item-action patch series, rebased onto v10.11.11 as
#       committed history on this fork's tracked branch (tip `c29757148f`, re-rooted from the
#       prior `e83a7e62f2..07de15dcd7` range onto the new base tag).
#   Because the patch is already committed on the branch this Dockerfile builds from, there is
#   NO `git apply`/`git am` step here (verified by `jellyfin:patch-contract-verify`, recorded in
#   submodules/jellyfin/ARTIFACTS.md). The four named build DLLs — MediaBrowser.Controller.dll,
#   Jellyfin.LiveTv.dll (both carry the patch surface) and MediaBrowser.Model.dll, Jellyfin.Api.dll
#   (stock in this patch) — are ordinary outputs of `dotnet publish Jellyfin.Server` below.
#
# PLUGIN DELIVERY — preload-staged, installed by the entrypoint (see ARTIFACTS.md "Container image"):
#   Jellyfin loads plugins from ${JELLYFIN_DATA_DIR}/plugins, and /var/lib/jellyfin is a runtime
#   PVC (colocation-persistence-contract), so anything baked directly under it is shadowed by the
#   mount. Every plugin — baked here or supplied at deploy time — is instead staged read-only under
#   ${JELLYFIN_PLUGIN_PRELOAD_DIR}, and the entrypoint installs each staged plugin folder into the
#   (PVC-mounted) data-dir plugins folder on first boot only (idempotent; never clobbers an
#   operator-updated install). See deploy/docker-entrypoint.sh.
#     * `Jellyfin.Pgsql` (task `pgsql-plugin-bundle`) IS built and baked by THIS Dockerfile: it
#       vendors the upstream JPVenson/Jellyfin.Pgsql provider at a pinned tag+SHA (see
#       Jellyfin.Pgsql/UPSTREAM.md) and stages the built DLL + meta.json into the preload dir below.
#       It reads its Postgres DSN entirely from POSTGRES_HOST/PORT/DB/USER/PASSWORD env vars (never
#       a hardcoded DSN) — the per-color `jellyfin_dev`/`jellyfin_prod` logical DB selection is
#       wired through those env vars by the deploy chart values (owned by phantom-library's Postgres
#       P4 Stage-A), not by this image.
#     * `Jellyfin.Plugin.PhantomLibrary` (the phantom-library plugin) IS baked here too, at a pinned
#       ref (ARG PHANTOM_LIBRARY_REF): its build lives in a separate repo that ProjectReferences this
#       patched fork (the fork is normally its `jellyfin/` submodule). Stage 2c clones it at that ref,
#       supplies THIS image's fork source as `./jellyfin` so the plugin binds against the exact fork
#       we ship, and packages it with `jprm` (the same tool phantom-library's release.yaml uses, which
#       emits a correct standalone plugin package — plugin DLL + private deps, host assemblies
#       excluded). Bump PHANTOM_LIBRARY_REF (and repin the deploy image) to ship a newer plugin. Its
#       Postgres DSN also comes from POSTGRES_*/PHANTOM_POSTGRES_* env set by the deploy chart, never
#       baked here.
#
# BUILD (amd64):
#   podman build -t ghcr.io/spencerharmon/jellyfin-phantom:10.11.11 -f Dockerfile .
#   (or `docker build ...`; build context = this fork's repo root)

ARG DOTNET_VERSION=9.0
ARG JELLYFIN_WEB_VERSION=v10.11.11

########################################
# Stage 1 — build the web client (pinned to the matching server release)
########################################
FROM node:20-alpine AS web-builder
ARG JELLYFIN_WEB_VERSION
RUN apk add --no-cache curl git zlib zlib-dev autoconf g++ make libpng-dev gifsicle alpine-sdk \
        automake libtool gcc musl-dev nasm python3 \
 && curl -L "https://github.com/jellyfin/jellyfin-web/archive/${JELLYFIN_WEB_VERSION}.tar.gz" | tar zxf - \
 && cd jellyfin-web-* \
 && npm ci --no-audit --unsafe-perm \
 && npm run build:production \
 && mv dist /dist

########################################
# Stage 2 — publish the patched server (self-contained, linux-x64)
########################################
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} AS server-builder
WORKDIR /repo
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
# Copy the full fork checkout — the tracked branch already carries the additive patch as history,
# so this build compiles the patched sources directly (no patch-apply step; fail-loud is moot).
COPY . .
RUN dotnet publish Jellyfin.Server \
        --configuration Release \
        --output /jellyfin \
        --self-contained \
        --runtime linux-x64 \
        -p:DebugSymbols=false -p:DebugType=none

########################################
# Stage 2b — build the vendored Postgres provider plugin (task pgsql-plugin-bundle)
########################################
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} AS pgsql-plugin-builder
WORKDIR /repo
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
COPY . .
RUN dotnet publish Jellyfin.Pgsql/Jellyfin.Pgsql.csproj \
        --configuration Release \
        --output /pgsql-plugin \
        -p:DebugSymbols=false -p:DebugType=none \
 && cp Jellyfin.Pgsql/meta.json /pgsql-plugin/meta.json

########################################
# Stage 2c — build the phantom-library plugin (baked; postgres-capable, pinned ref)
########################################
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} AS phantom-plugin-builder
# Pinned phantom-library commit carrying the PhantomDb Postgres provider (plugin 0.4.0.0).
ARG PHANTOM_LIBRARY_REF=c692ffd113dcdca32f574cbb7a843b609f26d650
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
WORKDIR /phantom
# jprm (Jellyfin Plugin Repository Manager) produces a correct standalone plugin package; the SDK
# base ships neither git nor python/jprm/unzip.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git python3 python3-pip ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir --break-system-packages jprm
# Clone phantom-library at the pinned ref, then replace its `jellyfin/` submodule dir with THIS
# image's fork source so the plugin's ProjectReferences bind against the exact patched fork we ship.
RUN git clone https://github.com/spencerharmon/phantom-library.git . \
 && git checkout "${PHANTOM_LIBRARY_REF}" \
 && rm -rf jellyfin
COPY . ./jellyfin
# Reference set of assemblies the Jellyfin host already ships (its published server output). The
# bundle step below copies ONLY dependencies absent from this set, so host-provided framework /
# extension assemblies (Microsoft.Extensions.*, System.Diagnostics.DiagnosticSource, Emby.Naming,
# Jellyfin.*, prometheus-net, ...) resolve from the host's Default load context at runtime -- REQUIRED
# for correctness: Jellyfin loads each plugin in an isolated PluginLoadContext, and bundling a
# host-provided assembly (e.g. Microsoft.Extensions.DependencyInjection.Abstractions) gives the plugin
# a second copy of IServiceCollection, breaking DI type identity when the host calls the plugin's
# RegisterServices. OpenTelemetry is pinned (in phantom-library) to the .NET 9-aligned 1.10.0 so it
# binds the host's DiagnosticSource 9.0 rather than demanding 10.0.
COPY --from=server-builder /jellyfin /host-ref
# Mark the patched-Jellyfin ProjectReferences as compile-only (Private=false + ExcludeAssets=runtime)
# so `dotnet publish` below emits ONLY the plugin + its own NuGet dependency closure -- NOT the host
# fork assemblies or their third-party transitive deps (SkiaSharp, etc.). This makes the bundle step
# a clean "copy the whole publish output", which correctly captures version OVERRIDES the plugin
# pulls over the shared framework (e.g. OpenTelemetry 1.15.3 drags System.Diagnostics.DiagnosticSource
# 10.0.0, newer than .NET 9's built-in 9.0.0). Compile assets are retained, so the plugin still binds
# the patched host types at build time. jprm (which only packages the plugin DLL) is unaffected. Every
# <ProjectReference> in this csproj is a Jellyfin fork ref, so the sed targets exactly those 5.
RUN sed -i -E 's#(<ProjectReference[^/]*)/>#\1Private="false" ExcludeAssets="runtime" />#' \
        src/Jellyfin.Plugin.PhantomLibrary/Jellyfin.Plugin.PhantomLibrary.csproj \
 && echo "patched $(grep -c 'ExcludeAssets="runtime"' src/Jellyfin.Plugin.PhantomLibrary/Jellyfin.Plugin.PhantomLibrary.csproj) ProjectReferences to compile-only"
# Package the plugin (Release, version from build.yaml) and unpack the zip into a single plugin
# folder for the preload dir. `mkdir -p /artifacts` FIRST: jprm writes its packaged zip to
# --output but does NOT create that directory, so without it jprm fails with
# `[Errno 2] No such file or directory: '/artifacts/<name>_<version>.zip'` AFTER compiling the
# DLLs. phantom-library's own release.yaml does the same `mkdir -p artifacts` before jprm.
#
# build.yaml `artifacts:` lists ONLY the plugin DLL, so the jprm zip ships none of the plugin's
# NuGet dependencies. 0.3.0.0's deps (Microsoft.Data.Sqlite + SQLitePCLRaw) happened to be
# host-provided, but 0.4.0.0 adds OpenTelemetry (+ its Grpc/Protobuf closure) and Npgsql/NCrontab
# which the Jellyfin host does NOT ship, so the plugin fails to load without them. We `dotnet publish`
# the plugin -- emitting only its own closure thanks to the compile-only ProjectReferences above --
# and bundle every DLL the host LACKS (checked by name against /host-ref), EXCEPT the plugin DLL
# itself (already unzipped). Host-provided assemblies are intentionally NOT bundled (see /host-ref
# comment above), which also keeps the SQLite native stack resolving from the host ALC.
RUN mkdir -p /artifacts \
 && jprm --verbosity=debug plugin build . --output=/artifacts \
        --dotnet-configuration=Release --dotnet-framework=net9.0 \
 && mkdir -p /phantom-plugin \
 && unzip -o /artifacts/*.zip -d /phantom-plugin \
 && dotnet publish src/Jellyfin.Plugin.PhantomLibrary/Jellyfin.Plugin.PhantomLibrary.csproj \
        -c Release -f net9.0 --no-self-contained -o /phantom-publish \
 && for f in /phantom-publish/*.dll; do \
        b="$(basename "$f")"; \
        [ "$b" = Jellyfin.Plugin.PhantomLibrary.dll ] && continue; \
        [ -f "/host-ref/$b" ] && continue; \
        cp -n "$f" /phantom-plugin/ ; \
    done \
 && echo "=== phantom plugin dir contents ===" && ls -1 /phantom-plugin

########################################
# Stage 3 — runtime
########################################
FROM debian:bookworm-slim AS app

ARG DEBIAN_FRONTEND=noninteractive
ARG APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn

# NVIDIA passthrough hints (harmless when no GPU is present).
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

# --- Directory contract (colocation-persistence-contract): data + config are PVCs at runtime ---
ENV JELLYFIN_DATA_DIR=/var/lib/jellyfin
ENV JELLYFIN_CONFIG_DIR=/etc/jellyfin
ENV JELLYFIN_CACHE_DIR=/var/cache/jellyfin
ENV JELLYFIN_LOG_DIR=/var/log/jellyfin
ENV JELLYFIN_WEB_DIR=/jellyfin/jellyfin-web
ENV JELLYFIN_FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg
# Staging dir the entrypoint installs plugins from (baked preload OR sidecar/init-container drop).
ENV JELLYFIN_PLUGIN_PRELOAD_DIR=/opt/jellyfin/plugins-preload
# Cutover-safe network.xml default, seeded into ${JELLYFIN_CONFIG_DIR} on first boot when absent.
ENV JELLYFIN_NETWORK_CONFIG_DEFAULT=/usr/share/jellyfin/config-defaults/network.xml
ENV HEALTHCHECK_URL=http://localhost:8096/health

# jellyfin-ffmpeg7 + VAAPI drivers from the official Jellyfin apt repo. (Intel NEO OpenCL
# compute-runtime — used only for advanced Intel tone-mapping — is intentionally omitted to keep
# the image reproducible without pinning fragile external GitHub release .debs; VAAPI transcode
# via mesa-va-drivers + jellyfin-ffmpeg is retained. See ARTIFACTS.md.)
RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y ca-certificates gnupg curl tini \
 && curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/debian-jellyfin.gpg \
 && echo "deb [arch=$( dpkg --print-architecture )] https://repo.jellyfin.org/$( awk -F'=' '/^ID=/{ print $NF }' /etc/os-release ) $( awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release ) main" > /etc/apt/sources.list.d/jellyfin.list \
 # PGDG repo for postgresql-client-16: the Jellyfin.Pgsql provider shells out to `pg_dump`
 # (MigrationBackupFast) and `psql` (RestoreBackupFast) to back up / restore the Postgres DB
 # around startup migrations. Without a client the server dies with `An error occurred trying to
 # start process 'pg_dump' ... No such file or directory` before the EF migrations build the
 # schema. The client MAJOR must be >= the server (16.x here): bookworm's default postgresql-client
 # is 15, whose pg_dump refuses a v16 server, so pull v16 from apt.postgresql.org.
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg \
 && echo "deb [arch=$( dpkg --print-architecture )] https://apt.postgresql.org/pub/repos/apt $( awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release )-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y mesa-va-drivers jellyfin-ffmpeg7 openssl locales postgresql-client-16 \
 && apt-get remove gnupg -y \
 && apt-get clean autoclean -y \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen \
 && mkdir -p "${JELLYFIN_DATA_DIR}" "${JELLYFIN_CONFIG_DIR}" "${JELLYFIN_CACHE_DIR}" "${JELLYFIN_LOG_DIR}" \
            "${JELLYFIN_PLUGIN_PRELOAD_DIR}" "$( dirname "${JELLYFIN_NETWORK_CONFIG_DEFAULT}" )" \
 && chmod 0770 "${JELLYFIN_DATA_DIR}" "${JELLYFIN_CONFIG_DIR}" "${JELLYFIN_CACHE_DIR}" "${JELLYFIN_LOG_DIR}"

ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en

# Patched server + web client.
COPY --from=server-builder /jellyfin /jellyfin
COPY --from=web-builder /dist "${JELLYFIN_WEB_DIR}"

# Baked plugin: vendored Postgres provider (task pgsql-plugin-bundle), staged into the preload dir
# above; the entrypoint installs it into ${JELLYFIN_DATA_DIR}/plugins on first boot (see comment
# atop this file). DSN comes from POSTGRES_* env vars set by the deploy chart values — never baked
# here.
COPY --from=pgsql-plugin-builder /pgsql-plugin "${JELLYFIN_PLUGIN_PRELOAD_DIR}/Jellyfin.Pgsql"

# Baked plugin: phantom-library plugin (postgres-capable, pinned ref), staged into the preload dir;
# the entrypoint installs it into ${JELLYFIN_DATA_DIR}/plugins on first boot. Built by stage 2c via
# jprm against THIS image's fork. Supersedes the prior manual-PVC install as the delivery mechanism.
COPY --from=phantom-plugin-builder /phantom-plugin "${JELLYFIN_PLUGIN_PRELOAD_DIR}/Jellyfin.Plugin.PhantomLibrary"

# Phantom Library web-UI shims (kebab menu + source picker, and item badges).
# Jellyfin 10.11.x BrandingOptions only exposes CustomCss (no CustomJs), and the
# SPA wraps CustomCss in a <style> tag, so a CSS-injected <script> never executes.
# phantom-library's install.sh works around this on a distro install by patching
# jellyfin-web/index.html directly; this image builds a STOCK jellyfin-web, so we
# replicate that exact injection here (baked, so it survives PVC mounts and pod
# restarts). The two shims are served (no-auth) by the plugin's own controllers at
# /Plugins/PhantomLibrary/kebab.js and /Plugins/PhantomLibrary/badges.js. Sentinel
# comments keep the injection idempotent + greppable; verified non-empty post-edit.
RUN set -eux; \
    idx="${JELLYFIN_WEB_DIR}/index.html"; \
    test -f "$idx"; \
    grep -q 'phantom-library-kebab' "$idx" \
      || sed -i 's|</body>|<!--phantom-library-kebab--><script src="/Plugins/PhantomLibrary/kebab.js" defer></script></body>|' "$idx"; \
    grep -q 'phantom-library-badges' "$idx" \
      || sed -i 's|</body>|<!--phantom-library-badges--><script src="/Plugins/PhantomLibrary/badges.js" defer></script></body>|' "$idx"; \
    grep -q 'phantom-library-kebab' "$idx"; \
    grep -q 'phantom-library-badges' "$idx"

# Cutover-safe network.xml (bluegreen-dns-contract) as the seed default + entrypoint.
COPY deploy/network.xml /usr/share/jellyfin/config-defaults/network.xml
COPY deploy/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

EXPOSE 8096

# tini reaps zombies (jellyfin spawns ffmpeg); entrypoint seeds dirs/config/plugins then execs jellyfin.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]

HEALTHCHECK --interval=30s --timeout=30s --start-period=20s --retries=3 \
    CMD curl -Lk -fsS "${HEALTHCHECK_URL}" || exit 1
