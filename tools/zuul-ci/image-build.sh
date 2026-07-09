#!/usr/bin/env bash
# tools/zuul-ci/image-build.sh
#
# Zuul CI gate 3 of 3 for the patched-Jellyfin fork: build container-image's
# repo/Dockerfile on every change, proving the deployable image still builds.
# Runs identically in Zuul (playbooks/jellyfin-image-build.yaml) and locally on
# a node with podman or docker.
#
# This is the CHECK/GATE half only — it builds and does NOT push. Publishing
# ghcr.io/spencerharmon/jellyfin-phantom:10.11.9 to a registry is the live
# release path (registry credentials + a tag-triggered pipeline) and is
# intentionally out of scope here (see docs/ci-zuul.md), mirroring gostream's
# gostream-image-build.
#
# Knobs (env):
#   JELLYFIN_CI_DRYRUN=1     toolchain-agnostic dry run: a full image build
#                            needs network (jellyfin-web npm, NuGet restore,
#                            repo.jellyfin.org apt) and heavy compile/disk, so
#                            the dry run does NOT build — it asserts the
#                            Dockerfile is present and prints the build command.
#                            Used by tools/zuul-ci/verify-zuul-config.py.
#   JELLYFIN_CI_IMAGE=<ref>  image tag to build (default jellyfin-phantom:zuul-ci-check).
#   JELLYFIN_CI_BUILDER=<bin> force the builder (podman|docker); default: autodetect.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

DRYRUN="${JELLYFIN_CI_DRYRUN:-0}"
IMAGE="${JELLYFIN_CI_IMAGE:-jellyfin-phantom:zuul-ci-check}"
DOCKERFILE="$REPO_ROOT/Dockerfile"

log()  { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

pick_builder() {
    if [ -n "${JELLYFIN_CI_BUILDER:-}" ]; then
        printf '%s' "$JELLYFIN_CI_BUILDER"; return 0
    fi
    if command -v podman >/dev/null 2>&1; then printf 'podman'; return 0; fi
    if command -v docker >/dev/null 2>&1; then printf 'docker'; return 0; fi
    return 1
}

log "jellyfin image-build gate"
note "repo root:   $REPO_ROOT"
note "dockerfile:  $DOCKERFILE"
note "image tag:   $IMAGE (build only — never pushed)"
note "dry run:     $DRYRUN"

# --- 1. Dockerfile present --------------------------------------------------
log "1. Dockerfile present"
[ -f "$DOCKERFILE" ] || die "container-image Dockerfile missing at $DOCKERFILE"
note "ok: $DOCKERFILE"

# --- 2. build (no push) -----------------------------------------------------
log "2. build the image from Dockerfile (context = repo root, no push)"
if [ "$DRYRUN" = 1 ]; then
    note "DRYRUN: <podman|docker> build -t $IMAGE -f Dockerfile ."
    note "DRYRUN: (network + heavy compile — not built here; run on a build node)"
else
    builder="$(pick_builder)" || die "no container builder found (need podman or docker)"
    note "builder: $builder"
    "$builder" build -t "$IMAGE" -f "$DOCKERFILE" .
    note "built (not pushed): $IMAGE"
fi

log "image-build gate PASSED"
