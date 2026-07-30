# syntax=docker/dockerfile:1
#
# Patched-Jellyfin container image — task `jellyfin:container-image` (ROI Priority 3, KEYSTONE).
#
# WHAT THIS BUILDS
#   A deployable image of the ADDITIVE-patched Jellyfin fork:
#     * base Jellyfin v10.11.9 (base SHA e83a7e62f2), and
#     * the additive channel-refresh patch that already lives as committed history on this
#       fork's tracked branch `phantom-library/patch-base-10.11.9` (tip 07de15dcd7).
#   Because the patch is already committed on the branch this Dockerfile builds from, there is
#   NO `git apply`/`git am` step here (verified by `jellyfin:patch-contract-verify`, recorded in
#   submodules/jellyfin/ARTIFACTS.md). The four named build DLLs — MediaBrowser.Controller.dll,
#   Jellyfin.LiveTv.dll (both carry the patch surface) and MediaBrowser.Model.dll, Jellyfin.Api.dll
#   (stock in this patch) — are ordinary outputs of `dotnet publish Jellyfin.Server` below.
#
# PLUGIN DELIVERY — documented init, NOT baked (see ARTIFACTS.md "Container image"):
#   Jellyfin loads plugins from ${JELLYFIN_DATA_DIR}/plugins, and /var/lib/jellyfin is a runtime
#   PVC (colocation-persistence-contract), so anything baked under it is shadowed by the mount.
#   The `phantom-library` plugin DLL is ALSO built from a separate repo (it ProjectReferences this
#   patched fork) and no phantom-library task yet emits a standalone consumable plugin artifact to
#   pin — so this image does NOT build or bake the plugin. Instead the entrypoint INSTALLS, on
#   start, any plugin folders staged read-only under ${JELLYFIN_PLUGIN_PRELOAD_DIR} into the
#   (PVC-mounted) data-dir plugins folder if absent. flux's phantom-library-bluegreen-deploy
#   supplies the phantom-library-built plugin at that path (init-container / sidecar / mount).
#   See deploy/docker-entrypoint.sh.
#
# BUILD (amd64):
#   podman build -t ghcr.io/spencerharmon/jellyfin-phantom:10.11.9 -f Dockerfile .
#   (or `docker build ...`; build context = this fork's repo root)

ARG DOTNET_VERSION=9.0
ARG JELLYFIN_WEB_VERSION=v10.11.9

########################################
# Stage 0 — gostream binary (single-container consolidation).
# k8s cannot share a mount namespace between containers, so a FUSE mounted by a
# separate gostream container is invisible (content-wise) to Jellyfin. We instead
# co-locate gostream IN this image and run both processes in one mount namespace
# (the host's original layout). Pinned by immutable digest; bump deliberately.
########################################
FROM git.spencerharmon.com/zuul/gostream@sha256:8fbd795c03f8f11d465e68e62fd39921fd810827993c83f6bdf5c478f3af6031 AS gostream-bin

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
      fuse3 ffmpeg iptables \
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

# --- gostream co-location (single-container FUSE consolidation) ------------------
# The gostream binary + a supervisor entrypoint that mounts the virtual-MKV FUSE
# and then starts Jellyfin in the SAME mount namespace (see combined-entrypoint.sh).
# Defaults put the FUSE at /var/gostream/gostream-mkv-virtual so it matches the
# plugin's GostreamMoviesRoot/GostreamShowsRoot exactly (no path translation).
# These GOSTREAM_* envs are overridable from the chart; the config file itself is
# provided at runtime (ConfigMap + Secret) at MKV_PROXY_CONFIG_PATH.
COPY --from=gostream-bin /usr/local/bin/gostream /usr/local/bin/gostream
COPY deploy/combined-entrypoint.sh /usr/local/bin/combined-entrypoint.sh
RUN chmod 0755 /usr/local/bin/combined-entrypoint.sh
ENV GOSTREAM_ROOT_PATH=/usr/local/state \
    GOSTREAM_SOURCE_PATH=/mnt/gostream-mkv-real \
    GOSTREAM_MOUNT_PATH=/var/gostream/gostream-mkv-virtual \
    GOSTREAM_STATE_DIR=/usr/local/state/STATE \
    GOSTREAM_LOG_DIR=/usr/local/state/logs \
    MKV_PROXY_CONFIG_PATH=/etc/gostream/config.json

EXPOSE 8096 8080 9080 8090

# tini reaps zombies (jellyfin spawns ffmpeg); entrypoint seeds dirs/config/plugins then execs jellyfin.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/combined-entrypoint.sh"]

HEALTHCHECK --interval=30s --timeout=30s --start-period=20s --retries=3 \
    CMD curl -Lk -fsS "${HEALTHCHECK_URL}" || exit 1
