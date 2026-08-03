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
#     * `phantom-library` is NOT baked here: it is built from a separate repo (it ProjectReferences
#       this patched fork) and no phantom-library task yet emits a standalone consumable plugin
#       artifact to pin, so flux's phantom-library-bluegreen-deploy supplies it at the same preload
#       path at deploy time (init-container / sidecar / mount) instead.
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
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y mesa-va-drivers jellyfin-ffmpeg7 openssl locales \
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
