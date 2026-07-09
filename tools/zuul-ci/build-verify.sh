#!/usr/bin/env bash
# tools/zuul-ci/build-verify.sh
#
# Zuul CI gate 2 of 3 for the patched-Jellyfin fork: build the fork and assert
# the four named DLLs exist and expose the REAL patch surfaces. Runs identically
# in Zuul (playbooks/jellyfin-build-verify.yaml) and locally on a .NET 9 node.
#
# REAL SURFACES (verified by jellyfin:patch-contract-verify via an actual
# `dotnet build -c Release` + binary grep, recorded in
# submodules/jellyfin/ARTIFACTS.md "Surface check"):
#   MediaBrowser.Controller.dll : IChannelItemRefresh, IChannelItemRefreshManager
#   Jellyfin.LiveTv.dll         : IChannelItemRefreshManager, RefreshChannelItemAsync
#   MediaBrowser.Model.dll      : (stock in this patch — asserted PRESENT only)
#   Jellyfin.Api.dll            : (stock in this patch — asserted PRESENT only)
#
# DELIBERATELY NOT ASSERTED: `IItemActionProvider` / `/Items/{itemId}/Actions`.
# ROI.md/PLAN.md and docs/tasks/zuul-ci.md list those as patch surface, but
# patch-contract-verify proved by exhaustive diff + build + binary grep that
# they do NOT exist anywhere in the fork (a documentation error carried into the
# ROI, see ARTIFACTS.md "Discrepancy"). Asserting a surface that does not exist
# would fake a contract; this gate asserts the two interfaces that are REAL and
# leaves the discrepancy for operator/reconcile disposition.
#
# Knobs (env):
#   JELLYFIN_CI_DRYRUN=1   toolchain-agnostic dry run: do NOT build (the fork
#                          pins .NET 9 via global.json rollForward:latestMinor,
#                          which a .NET 10-only box cannot satisfy, and never
#                          commit an override — ARTIFACTS.md). Print the steps
#                          and the surface contract, exit 0. Used by the in-repo
#                          regression check tools/zuul-ci/verify-zuul-config.py.
#   JELLYFIN_CI_OUT=<dir>  publish output dir (default <repo>/ci-out).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

DRYRUN="${JELLYFIN_CI_DRYRUN:-0}"
OUT="${JELLYFIN_CI_OUT:-$REPO_ROOT/ci-out}"

# No reusable build servers on a (potentially shared) CI node.
export MSBUILDDISABLENODEREUSE=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
DOTNET_FLAGS=(--configuration Release -p:UseSharedCompilation=false)

# The four named build DLLs and the REAL surfaces each must expose. Format:
#   <dll>|<symbol>[,<symbol>...]   ("-" = existence only, no surface grep)
DLL_SURFACES=(
    "MediaBrowser.Controller.dll|IChannelItemRefresh,IChannelItemRefreshManager"
    "Jellyfin.LiveTv.dll|IChannelItemRefreshManager,RefreshChannelItemAsync"
    "MediaBrowser.Model.dll|-"
    "Jellyfin.Api.dll|-"
)

log()  { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local ec=$?
    dotnet build-server shutdown >/dev/null 2>&1 || true
    exit "$ec"
}
[ "$DRYRUN" = 1 ] || trap cleanup EXIT

log "jellyfin build + surface gate"
note "repo root:    $REPO_ROOT"
note "output dir:   $OUT"
note "dotnet flags: ${DOTNET_FLAGS[*]}"
note "dry run:      $DRYRUN"

# --- 1. build ---------------------------------------------------------------
log "1. dotnet publish Jellyfin.Server"
if [ "$DRYRUN" = 1 ]; then
    note "DRYRUN: dotnet publish Jellyfin.Server ${DOTNET_FLAGS[*]} --output $OUT"
    note "DRYRUN: (fork pins .NET 9 via global.json; no build attempted here)"
else
    command -v dotnet >/dev/null 2>&1 || die "dotnet SDK not found on PATH"
    rm -rf "$OUT"
    dotnet publish Jellyfin.Server "${DOTNET_FLAGS[@]}" --output "$OUT"
fi

# --- 2. the four DLLs exist + expose the real surfaces ----------------------
log "2. four named DLLs exist and expose the REAL surfaces"
for entry in "${DLL_SURFACES[@]}"; do
    dll="${entry%%|*}"
    syms="${entry#*|}"
    path="$OUT/$dll"

    if [ "$DRYRUN" = 1 ]; then
        if [ "$syms" = "-" ]; then
            note "DRYRUN: assert exists: $dll (stock)"
        else
            note "DRYRUN: assert exists + grep [$syms]: $dll"
        fi
        continue
    fi

    [ -f "$path" ] || die "expected build DLL missing: $dll ($path)"
    note "exists: $dll"
    [ "$syms" = "-" ] && continue

    IFS=',' read -r -a want <<< "$syms"
    for sym in "${want[@]}"; do
        grep -aq -- "$sym" "$path" \
            || die "surface '$sym' NOT found in $dll (patch build regressed?)"
        note "  surface ok: $dll :: $sym"
    done
done

log "build + surface gate PASSED"
