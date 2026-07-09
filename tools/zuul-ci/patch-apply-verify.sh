#!/usr/bin/env bash
# tools/zuul-ci/patch-apply-verify.sh
#
# Zuul CI gate 1 of 3 for the patched-Jellyfin fork: prove the ADDITIVE
# channel-refresh patch applies IDEMPOTENTLY at the base tag and FAIL LOUD on
# any non-applying hunk (never skip / special-case one). Runs identically in
# Zuul (playbooks/jellyfin-patch-apply.yaml) and locally.
#
# WHAT THE PATCH IS (verified by jellyfin:patch-contract-verify, recorded in
# submodules/jellyfin/ARTIFACTS.md): the fork's tracked branch carries the patch
# as 4 already-committed commits on top of base tag v10.11.9 (e83a7e62f2):
#     e83a7e62f2..07de15dcd7  =  5 files, 535(+)/7(-)
#   NEW: MediaBrowser.Controller/Channels/IChannelItemRefresh.cs
#   NEW: MediaBrowser.Controller/Channels/IChannelItemRefreshManager.cs
#   NEW: tests/Jellyfin.LiveTv.Tests/Channels/ChannelManagerRefreshTests.cs
#   MOD: src/Jellyfin.LiveTv/Channels/ChannelManager.cs
#   MOD: src/Jellyfin.LiveTv/Extensions/LiveTvServiceCollectionExtensions.cs
# Later commits on the branch (deploy assets, the container-image Dockerfile) do
# NOT touch any of those 5 files, so `git diff <base> HEAD -- <the 5 files>`
# isolates exactly the channel-refresh patch regardless of how far the tip has
# advanced.
#
# WHAT THIS GATE PROVES
#   1. the recorded base SHA is a real ancestor of the checkout's HEAD;
#   2. the recorded base SHA still matches upstream jellyfin's v10.11.9 tag
#      (upstream has not re-tagged / force-pushed) — network check, skipped in
#      the toolchain-agnostic dry run;
#   3. the patch is file-level ADDITIVE: exactly the 3 new + 2 modified files,
#      zero deletions / renames of pre-existing files;
#   4. the patch applies to a PRISTINE base checkout with `git apply`, is
#      IDEMPOTENT (a second apply is a detected no-op, not a double-apply and
#      not a hard failure), and FAILS LOUD if it neither applies nor is already
#      applied — a non-applying hunk is never skipped;
#   5. the applied result is BYTE-IDENTICAL to the fork's own version of each of
#      the 5 files (base + patch == fork).
#
# Knobs (env):
#   JELLYFIN_CI_DRYRUN=1        toolchain-agnostic dry run: skip the network
#                               upstream-tag check (2) and materialize the
#                               pristine base from THIS repo's own base-SHA
#                               objects instead of cloning upstream. Steps
#                               1,3,4,5 still run for real. Used by the in-repo
#                               regression check tools/zuul-ci/verify-zuul-config.py.
#   JELLYFIN_CI_BASE_SHA=<sha>  override the recorded base SHA (default below).
#   JELLYFIN_CI_BASE_TAG=<tag>  override the base tag name (default v10.11.9).
#   JELLYFIN_UPSTREAM_REPO=<url> upstream clone URL for the base tag.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

DRYRUN="${JELLYFIN_CI_DRYRUN:-0}"
BASE_SHA="${JELLYFIN_CI_BASE_SHA:-e83a7e62f26443f7dd98f126d6955ac1af090125}"
BASE_TAG="${JELLYFIN_CI_BASE_TAG:-v10.11.9}"
UPSTREAM_REPO="${JELLYFIN_UPSTREAM_REPO:-https://github.com/jellyfin/jellyfin.git}"

# The additive channel-refresh patch's files (ARTIFACTS.md "Additive-only").
NEW_FILES=(
    "MediaBrowser.Controller/Channels/IChannelItemRefresh.cs"
    "MediaBrowser.Controller/Channels/IChannelItemRefreshManager.cs"
    "tests/Jellyfin.LiveTv.Tests/Channels/ChannelManagerRefreshTests.cs"
)
MOD_FILES=(
    "src/Jellyfin.LiveTv/Channels/ChannelManager.cs"
    "src/Jellyfin.LiveTv/Extensions/LiveTvServiceCollectionExtensions.cs"
)
ALL_FILES=("${NEW_FILES[@]}" "${MOD_FILES[@]}")

log()  { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
sha256_of_head() { git show "HEAD:$1" | sha256sum | cut -d' ' -f1; }

sorted_lines() { printf '%s\n' "$@" | LC_ALL=C sort; }

log "jellyfin patch-apply gate"
note "repo root:    $REPO_ROOT"
note "base tag:     $BASE_TAG"
note "base SHA:     $BASE_SHA"
note "upstream:     $UPSTREAM_REPO"
note "dry run:      $DRYRUN"

# --- 1. base SHA is a real ancestor of HEAD ---------------------------------
log "1. base SHA is an ancestor of HEAD"
git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null \
    || die "base SHA $BASE_SHA is not present in this checkout (unshallow / wrong base?)"
git merge-base --is-ancestor "$BASE_SHA" HEAD \
    || die "base SHA $BASE_SHA is NOT an ancestor of HEAD ($(git rev-parse HEAD))"
note "ok: $BASE_SHA is an ancestor of $(git rev-parse --short HEAD)"

# --- 2. base SHA still matches upstream's tag (network; skipped in dry run) --
log "2. upstream $BASE_TAG tag still points at the recorded base SHA"
if [ "$DRYRUN" = 1 ]; then
    note "DRYRUN: skipping network ls-remote against $UPSTREAM_REPO"
else
    up_sha="$(git ls-remote "$UPSTREAM_REPO" "refs/tags/${BASE_TAG}^{}" | awk '{print $1}')"
    # Annotated tags resolve via ^{}; fall back to the lightweight ref.
    [ -n "$up_sha" ] || up_sha="$(git ls-remote "$UPSTREAM_REPO" "refs/tags/${BASE_TAG}" | awk '{print $1}')"
    [ -n "$up_sha" ] || die "could not resolve upstream tag $BASE_TAG at $UPSTREAM_REPO"
    [ "$up_sha" = "$BASE_SHA" ] \
        || die "upstream $BASE_TAG = $up_sha but fork records base $BASE_SHA (upstream re-tagged?)"
    note "ok: upstream $BASE_TAG = $up_sha"
fi

# --- 3. file-level additive guard -------------------------------------------
log "3. patch is file-level additive (3 new, 2 modified, 0 deleted/renamed)"
added="$(git diff --diff-filter=A --name-only "$BASE_SHA" HEAD -- "${ALL_FILES[@]}" | LC_ALL=C sort)"
modified="$(git diff --diff-filter=M --name-only "$BASE_SHA" HEAD -- "${ALL_FILES[@]}" | LC_ALL=C sort)"
gone="$(git diff --diff-filter=DR --name-only "$BASE_SHA" HEAD -- "${ALL_FILES[@]}" | LC_ALL=C sort)"

want_added="$(sorted_lines "${NEW_FILES[@]}")"
want_mod="$(sorted_lines "${MOD_FILES[@]}")"

[ "$added" = "$want_added" ] || die $'added-files mismatch.\n  want:\n'"$want_added"$'\n  got:\n'"$added"
[ "$modified" = "$want_mod" ] || die $'modified-files mismatch.\n  want:\n'"$want_mod"$'\n  got:\n'"$modified"
[ -z "$gone" ] || die $'patch deletes/renames pre-existing files (not additive):\n'"$gone"
note "ok: 3 new + 2 modified, no deletions/renames"

# --- derive the patch -------------------------------------------------------
WORK="$(mktemp -d)"
PATCH="$WORK/channel-refresh.patch"
BASE_DIR="$WORK/base"
mkdir -p "$BASE_DIR"
git diff "$BASE_SHA" HEAD -- "${ALL_FILES[@]}" > "$PATCH"
[ -s "$PATCH" ] || die "derived patch is empty"
note "derived patch: $(wc -l < "$PATCH") lines"

# --- 4a. materialize a PRISTINE base checkout -------------------------------
log "4. materialize pristine base $BASE_TAG"
if [ "$DRYRUN" = 1 ]; then
    note "DRYRUN: reconstructing base files from local $BASE_SHA (== upstream $BASE_TAG per ARTIFACTS.md)"
    # Only the MODIFIED files need to pre-exist at base content; NEW files must
    # be absent so the patch creates them. That is the exact on-disk shape a
    # fresh upstream checkout of the base tag presents to `git apply`.
    for f in "${MOD_FILES[@]}"; do
        mkdir -p "$BASE_DIR/$(dirname "$f")"
        git show "${BASE_SHA}:${f}" > "$BASE_DIR/$f"
    done
else
    note "cloning upstream $BASE_TAG (shallow)"
    git clone --quiet --depth 1 --branch "$BASE_TAG" "$UPSTREAM_REPO" "$BASE_DIR"
    got_base="$(git -C "$BASE_DIR" rev-parse HEAD)"
    [ "$got_base" = "$BASE_SHA" ] \
        || die "upstream $BASE_TAG clone HEAD $got_base != recorded base $BASE_SHA"
    note "ok: clone HEAD = $got_base"
fi

# --- 4b. idempotent apply, fail-loud on a non-applying hunk ------------------
log "4b. apply the patch to the pristine base (idempotent, fail-loud)"
apply_err="$WORK/apply.err"
if git -C "$BASE_DIR" apply --check -p1 "$PATCH" 2>"$apply_err"; then
    git -C "$BASE_DIR" apply -p1 "$PATCH"
    note "applied cleanly at base"
elif git -C "$BASE_DIR" apply --check -p1 -R "$PATCH" 2>/dev/null; then
    note "already applied at base (idempotent no-op)"
else
    printf '    git apply --check output:\n' >&2
    sed 's/^/      /' "$apply_err" >&2 || true
    die "patch neither applies nor is already applied — a non-applying hunk. \
NOT skipping/special-casing it (fail loud). Rebase the patch onto $BASE_TAG."
fi

# Idempotency: re-running apply on the now-patched tree must be a DETECTED
# no-op — it must NOT apply again (double-apply) and MUST reverse cleanly.
if git -C "$BASE_DIR" apply --check -p1 "$PATCH" 2>/dev/null; then
    die "patch still forward-applies after being applied — not idempotent (would double-apply)"
fi
git -C "$BASE_DIR" apply --check -p1 -R "$PATCH" 2>/dev/null \
    || die "applied patch is not reverse-applicable — unexpected non-idempotent state"
note "ok: second apply is a detected no-op (idempotent)"

# --- 5. byte-identity: base + patch == fork ---------------------------------
log "5. applied result is byte-identical to the fork's files"
for f in "${ALL_FILES[@]}"; do
    [ -f "$BASE_DIR/$f" ] || die "expected file missing after apply: $f"
    want="$(sha256_of_head "$f")"
    got="$(sha256_of "$BASE_DIR/$f")"
    [ "$want" = "$got" ] || die "byte mismatch after apply: $f (fork=$want applied=$got)"
    note "ok: $f"
done

log "patch-apply gate PASSED"
