#!/usr/bin/env bash
#
# jellyfin-phantom-plugin-content-probe.test.sh
# =============================================
# Definition-of-done probe for `jellyfin-phantom-image-stale-plugin-pin`.
#
# WHAT IT PROVES
# --------------
# A published `git.spencerharmon.com/images/jellyfin-phantom:<tag>` actually bakes a
# phantom-library plugin DLL that CONTAINS the `phantom_playback_outcome_total`
# Prometheus-net counter (the definitive per-attempt playback-outcome metric added by
# phantom-library commit 2ab4144 "playback-outcome-real-cause-dual-emit-001"). This is
# the exact gap this task exists to close: a prior build raced/missed the merge and
# published an image whose baked DLL lacked the metric entirely, even though the image
# build-timestamp post-dated the phantom-library merge. A build-date is NOT evidence;
# the DLL bytes are. This probe pulls the layer from the registry and byte-checks the
# raw DLL, so it can NEVER pass on a stale plugin the way a build-date inference did.
#
# It is a REAL integration probe against the live registry v2 API (curl + a self-contained
# python3 helper that does the manifest walk / layer scan / byte-substring assert). It
# is NOT a source-grep: the code under test is the *published binary artifact*, not this
# repo's tree.
#
# SANDBOX RULE (this install)
# ---------------------------
# The beehive check sandbox DENIES `bash`/`python3 -c`/`grep`/... as the *invoking command
# word*. This file is therefore invoked DIRECTLY by its executable path (its shebang runs
# it). It DOES invoke `python3` internally on a neighboring committed, on-disk helper
# (not `python3 -c ...` on the command
# line) — that is the script's own body doing its work, which the rule explicitly allows.
# The byte-substring assertion is performed by that python3 body itself (a plain
# `bytes.find`), never by a `grep`/`strings` pipe on the invoking command line.
#
# USAGE
# -----
#   ./scripts/tests/jellyfin-phantom-plugin-content-probe.test.sh [TAG]
#
#   TAG resolution order:
#     1. $1 (first CLI arg), else
#     2. $PHANTOM_IMAGE_TAG env, else
#     3. the 12-char short git SHA of HEAD in the checkout this runs from
#        (`git rev-parse --short=12 HEAD`) — which is EXACTLY the tag the publish
#        step computes (see .gitea/workflows/jellyfin-image-build.yml), so when the
#        runner runs this Check on the merged tree, it targets the merge's own tag.
#
#   Because the Gitea Actions build+publish is ASYNC relative to the merge that triggers
#   it, the probe POLLS the registry for the tag to appear (bounded by
#   $PHANTOM_PROBE_TIMEOUT seconds, default 1800 = 30m; $PHANTOM_PROBE_INTERVAL between
#   polls, default 30s). A tag that never appears within the window, a missing DLL, or a
#   DLL WITHOUT the metric all EXIT NON-ZERO.
#   Optional PHANTOM_EXPECT_VERSION, PHANTOM_EXPECT_SOURCE_REF,
#   PHANTOM_EXPECT_METHOD (ASCII), and PHANTOM_EXPECT_RUNTIME_LITERAL (UTF-16LE)
#   add binary provenance assertions. Manifest/layer digests are always verified.
#
# EXIT CODES
#   0  the resolved tag's baked plugin DLL contains phantom_playback_outcome_total
#   1  the tag published but the metric is absent / the DLL could not be located
#   2  the tag never appeared within the timeout, or an infra/tool failure
#
set -euo pipefail

REGISTRY_HOST="${PHANTOM_REGISTRY_HOST:-git.spencerharmon.com}"
IMAGE_REPO_PATH="${PHANTOM_IMAGE_REPO_PATH:-images/jellyfin-phantom}"
METRIC="${PHANTOM_METRIC:-phantom_playback_outcome_total}"
DLL_PATH_SUFFIX="opt/jellyfin/plugins-preload/Jellyfin.Plugin.PhantomLibrary/Jellyfin.Plugin.PhantomLibrary.dll"
POLL_TIMEOUT="${PHANTOM_PROBE_TIMEOUT:-1800}"
POLL_INTERVAL="${PHANTOM_PROBE_INTERVAL:-30}"

log() { printf '%s %s\n' "[$(date -u +%H:%M:%SZ)]" "$*" >&2; }
die() { log "FAIL: $*"; exit "${2:-2}"; }

# ---- resolve the tag -------------------------------------------------------------
TAG="${1:-${PHANTOM_IMAGE_TAG:-}}"
if [ -z "${TAG}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  if TAG="$(git -C "${SCRIPT_DIR}" rev-parse --short=12 HEAD 2>/dev/null)"; then
    log "no TAG given; defaulting to HEAD short sha: ${TAG}"
  else
    die "no TAG given and could not resolve git HEAD (pass a tag or set \$PHANTOM_IMAGE_TAG)"
  fi
fi
REF="${REGISTRY_HOST}/${IMAGE_REPO_PATH}:${TAG}"
log "probing ${REF} for baked plugin DLL containing '${METRIC}'"

for tool in curl jq python3; do
  command -v "${tool}" >/dev/null 2>&1 || die "required tool '${tool}' not on PATH"
done

# ---- anonymous bearer token for pull --------------------------------------------
get_token() {
  curl -sf \
    "https://${REGISTRY_HOST}/v2/token?service=${REGISTRY_HOST}&scope=repository:${IMAGE_REPO_PATH}:pull" \
    | jq -r '.token // .access_token // empty'
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="${SCRIPT_DIR}/jellyfin_phantom_plugin_content_probe.py"

probe_once() {
  local token
  token="$(get_token)" || return 2
  [ -n "${token}" ] || return 2
  jq -n \
    --arg host "${REGISTRY_HOST}" \
    --arg repo "${IMAGE_REPO_PATH}" \
    --arg tag "${TAG}" \
    --arg token "${token}" \
    --arg dll_suffix "${DLL_PATH_SUFFIX}" \
    --arg metric "${METRIC}" \
    --arg version "${PHANTOM_EXPECT_VERSION:-}" \
    --arg source_ref "${PHANTOM_EXPECT_SOURCE_REF:-}" \
    --arg method "${PHANTOM_EXPECT_METHOD:-}" \
    --arg runtime_literal "${PHANTOM_EXPECT_RUNTIME_LITERAL:-}" \
    '{host:$host, repo:$repo, tag:$tag, token:$token, dll_suffix:$dll_suffix,
      metric:$metric, version:$version, source_ref:$source_ref, method:$method,
      runtime_literal:$runtime_literal}' \
    | python3 "${HELPER}"
}

deadline=$(( $(date +%s) + POLL_TIMEOUT ))
attempt=0
while :; do
  attempt=$(( attempt + 1 ))
  set +e
  probe_once
  rc=$?
  set -e
  case "${rc}" in
    0) log "PASS: ${REF} baked DLL meets all requested expectations"; exit 0 ;;
    1) die "${REF} failed image integrity or plugin content expectations (see above)" 1 ;;
    *)
      now=$(date +%s)
      if [ "${now}" -ge "${deadline}" ]; then
        die "tag '${TAG}' did not become probeable with a valid manifest within ${POLL_TIMEOUT}s (attempt ${attempt}); rc=${rc}" 2
      fi
      log "tag not ready yet (attempt ${attempt}, rc=${rc}); retrying in ${POLL_INTERVAL}s"
      sleep "${POLL_INTERVAL}"
      ;;
  esac
done
