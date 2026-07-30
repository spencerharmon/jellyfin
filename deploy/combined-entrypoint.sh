#!/usr/bin/env bash
# combined-entrypoint.sh — single-container gostream + Jellyfin supervisor.
#
# WHY ONE CONTAINER: Kubernetes cannot share a mount namespace between two
# containers, so a FUSE filesystem mounted by one container is never visible
# (content-wise) to another — only the bare mountpoint propagates. The host ran
# gostream and Jellyfin as two processes in ONE mount namespace: gostream mounted
# the virtual-MKV FUSE at /var/gostream/gostream-mkv-virtual and Jellyfin read the
# SAME path directly. This image replicates that exactly by running both processes
# in one container. gostream mounts the FUSE at $GOSTREAM_MOUNT_PATH (default
# /var/gostream/gostream-mkv-virtual — the plugin's own GostreamMoviesRoot/
# GostreamShowsRoot parent), and Jellyfin, in the same namespace, sees it with no
# mount propagation and no path translation. The plugin's GostreamBaseUrl
# (127.0.0.1:9080) also still holds: same container = localhost.
#
# Supervision: gostream runs in the background; Jellyfin (via its own entrypoint)
# in the background too; if EITHER exits the whole container exits non-zero so
# Kubernetes restarts it clean. tini (PID 1, from the Dockerfile ENTRYPOINT) reaps
# zombies and forwards signals to this script.
set -euo pipefail

GOSTREAM_BIN=/usr/local/bin/gostream
CONFIG_PATH="${MKV_PROXY_CONFIG_PATH:-/etc/gostream/config.json}"
ROOT_PATH="${GOSTREAM_ROOT_PATH:-/usr/local/state}"
SOURCE_PATH="${GOSTREAM_SOURCE_PATH:-/mnt/gostream-mkv-real}"
MOUNT_PATH="${GOSTREAM_MOUNT_PATH:-/var/gostream/gostream-mkv-virtual}"
STATE_DIR="${GOSTREAM_STATE_DIR:-$ROOT_PATH/STATE}"
LOG_DIR="${GOSTREAM_LOG_DIR:-$ROOT_PATH/logs}"

log() { echo "[combined-entrypoint] $*" >&2; }

mkdir -p "$SOURCE_PATH" "$MOUNT_PATH" "$ROOT_PATH" "$STATE_DIR" "$LOG_DIR"

# Clean a stale FUSE layer left by a previous unclean exit (a bare, non-FUSE dir is fine).
if mountpoint -q "$MOUNT_PATH" 2>/dev/null && grep -q " $MOUNT_PATH fuse" /proc/mounts 2>/dev/null; then
  log "cleaning stale FUSE mount at $MOUNT_PATH"
  fusermount3 -uz "$MOUNT_PATH" 2>/dev/null || true
fi

if [ ! -f "$CONFIG_PATH" ]; then
  log "FATAL: missing required gostream config at $CONFIG_PATH"
  exit 1
fi

gostream_pid=""
jellyfin_pid=""

shutdown() {
  trap - INT TERM EXIT
  [ -n "$jellyfin_pid" ] && kill -TERM "$jellyfin_pid" 2>/dev/null || true
  [ -n "$gostream_pid" ] && kill -TERM "$gostream_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  fusermount3 -uz "$MOUNT_PATH" 2>/dev/null || true
}
trap shutdown INT TERM EXIT

log "starting gostream: $GOSTREAM_BIN --path $ROOT_PATH $SOURCE_PATH $MOUNT_PATH"
"$GOSTREAM_BIN" --path "$ROOT_PATH" "$SOURCE_PATH" "$MOUNT_PATH" &
gostream_pid="$!"

# Wait (up to 90s) for the FUSE mount to come up before starting Jellyfin, so the
# plugin never probes an unmounted path. Abort if gostream dies first.
mounted=0
for _ in $(seq 1 90); do
  if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
    mounted=1
    log "gostream FUSE mounted at $MOUNT_PATH"
    break
  fi
  if ! kill -0 "$gostream_pid" 2>/dev/null; then
    log "FATAL: gostream exited before mounting $MOUNT_PATH"
    exit 1
  fi
  sleep 1
done
if [ "$mounted" -ne 1 ]; then
  log "FATAL: gostream FUSE did not mount at $MOUNT_PATH within 90s"
  exit 1
fi

log "starting Jellyfin"
/usr/local/bin/docker-entrypoint.sh "$@" &
jellyfin_pid="$!"

# Block until EITHER supervised process exits, then tear the container down so
# Kubernetes restarts it cleanly (the shutdown trap unmounts the FUSE).
wait -n
log "a supervised process exited; shutting the container down"
exit 1
