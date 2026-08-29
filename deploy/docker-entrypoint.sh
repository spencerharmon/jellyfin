#!/bin/sh
# docker-entrypoint.sh — patched-Jellyfin image entrypoint (task jellyfin:container-image).
#
# Runs before the server every start. It is idempotent and NEVER clobbers operator/PVC state:
#   1. Ensure the data / config / cache / log dirs + the data-dir plugins folder exist. These are
#      PVC mounts at runtime (colocation-persistence-contract); mkdir -p is a no-op when present.
#   2. Seed the cutover-safe network.xml (bluegreen-dns-contract) into ${JELLYFIN_CONFIG_DIR} on
#      first boot ONLY when absent — Jellyfin's CreateNetworkConfiguration migration likewise only
#      writes network.xml when absent, so a pre-placed file wins and an operator edit is preserved.
#   3. Install any plugin folders staged read-only under ${JELLYFIN_PLUGIN_PRELOAD_DIR} into the
#      (PVC-mounted) ${JELLYFIN_DATA_DIR}/plugins folder, ONLY when the target folder is absent.
#      This is the documented plugin-install mechanism: the image ships no plugin, and flux's
#      phantom-library-bluegreen-deploy stages the phantom-library-built plugin DLL at that path
#      (init-container / sidecar / mounted volume). See Dockerfile + ARTIFACTS.md.
#   4. exec the patched jellyfin server (self-contained binary) with --ffmpeg; the directory env
#      vars set in the Dockerfile point the server at the paths above; :8096 comes from network.xml.
set -eu

DATA_DIR="${JELLYFIN_DATA_DIR:-/var/lib/jellyfin}"
CONFIG_DIR="${JELLYFIN_CONFIG_DIR:-/etc/jellyfin}"
CACHE_DIR="${JELLYFIN_CACHE_DIR:-/var/cache/jellyfin}"
LOG_DIR="${JELLYFIN_LOG_DIR:-/var/log/jellyfin}"
PLUGIN_PRELOAD_DIR="${JELLYFIN_PLUGIN_PRELOAD_DIR:-/opt/jellyfin/plugins-preload}"
NETWORK_CONFIG_DEFAULT="${JELLYFIN_NETWORK_CONFIG_DEFAULT:-/usr/share/jellyfin/config-defaults/network.xml}"
FFMPEG="${JELLYFIN_FFMPEG:-/usr/lib/jellyfin-ffmpeg/ffmpeg}"

log() { echo "[entrypoint] $*"; }

# 1. Directories (PVC mounts at runtime; no-op when they already exist).
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$CACHE_DIR" "$LOG_DIR" "$DATA_DIR/plugins"

# 2. Seed the cutover-safe network.xml only when the config dir does not already have one.
if [ -f "$NETWORK_CONFIG_DEFAULT" ] && [ ! -e "$CONFIG_DIR/network.xml" ]; then
    cp "$NETWORK_CONFIG_DEFAULT" "$CONFIG_DIR/network.xml"
    log "seeded cutover-safe network.xml -> $CONFIG_DIR/network.xml"
fi

# 3. Install/UPDATE staged plugin folders (each immediate subdir is one plugin). A staged plugin
#    is installed when absent, and UPDATED IN PLACE when its baked meta.json version differs from
#    the installed one. Version is the deploy contract: the image bakes the plugin at a pinned
#    version (build.yaml), so a plugin code change MUST bump that version to actually roll out.
#    Plugin CONFIGURATION lives in a separate dir (plugins/configurations/) and is never touched
#    here, so an update preserves operator config across restarts. Same-version -> left as-is.
plugin_meta_version() {  # $1 = plugin dir; echoes the meta.json "version" or empty
    _m="$1/meta.json"
    [ -f "$_m" ] || { echo ""; return; }
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_m" | head -n1
}
if [ -d "$PLUGIN_PRELOAD_DIR" ]; then
    for plugdir in "$PLUGIN_PRELOAD_DIR"/*/; do
        [ -d "$plugdir" ] || continue   # no matches -> literal glob; skip
        name=$(basename "$plugdir")
        target="$DATA_DIR/plugins/$name"
        staged_ver=$(plugin_meta_version "${plugdir%/}")
        installed_ver=$(plugin_meta_version "$target")
        if [ -e "$target" ] && [ -n "$staged_ver" ] && [ "$staged_ver" = "$installed_ver" ]; then
            log "plugin '$name' already at version '$installed_ver' — leaving as-is"
        elif [ -e "$target" ]; then
            rm -rf "$target"
            cp -a "$plugdir" "$target"
            log "updated plugin '$name' '$installed_ver' -> '$staged_ver' (config preserved)"
        else
            cp -a "$plugdir" "$target"
            log "installed plugin '$name' version '$staged_ver' -> $target"
        fi
    done
fi

# 4. Hand off to the patched server. Extra args (e.g. from the k8s command/args) pass through.
exec /jellyfin/jellyfin --ffmpeg "$FFMPEG" "$@"
