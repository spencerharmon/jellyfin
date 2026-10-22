#!/usr/bin/env bash
# Published-image byte provenance, not proof that zero seeding executes at runtime.
# Usage: jellyfin-phantom-zero-seed-probe.test.sh FULL_FORK_SHA
set -euo pipefail

if [[ $# != 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'Usage: %s FULL_FORK_SHA (40 lowercase hex characters; image tag is first 12)\n' "$0" >&2
  exit 2
fi

export PHANTOM_EXPECT_VERSION=0.5.7.7
export PHANTOM_EXPECT_SOURCE_REF=d9a58ece9e7111f86663efe0c608147c099205a3
export PHANTOM_EXPECT_METHOD=SeedPlaybackOutcomes
export PHANTOM_EXPECT_RUNTIME_LITERAL='Phantom OTLP runtime provenance:'
export PHANTOM_METRIC=phantom_playback_outcome_total
export PHANTOM_PROBE_TIMEOUT="${PHANTOM_PROBE_TIMEOUT:-0}"
printf 'fork_source_ref=%s image_tag=%s\n' "$1" "${1:0:12}"
exec "$(dirname "$0")/jellyfin-phantom-plugin-content-probe.test.sh" "${1:0:12}"
