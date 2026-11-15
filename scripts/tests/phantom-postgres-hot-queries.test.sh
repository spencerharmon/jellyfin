#!/usr/bin/env bash
set -euo pipefail
root="$(realpath "$(dirname "${BASH_SOURCE[0]}")/../..")"
project="$root/tests/Jellyfin.Postgres.Tests/Jellyfin.Postgres.Tests.csproj"
artifacts="$root/tests/Jellyfin.Postgres.Tests/artifacts"
mkdir -p "$artifacts"
export PHANTOM_HOT_QUERY_REPORT="${PHANTOM_HOT_QUERY_REPORT:-$artifacts/hot-queries.json}"
container=""
# Keep large image layers off quota-limited TMPDIR. Storage is disposable test-owned state.
engine=(podman --root "$artifacts/podman")
cleanup() {
    if [[ -n "$container" ]]; then "${engine[@]}" rm -f -v "$container" >/dev/null; fi
}
trap cleanup EXIT
if [[ -z "${PHANTOM_TEST_POSTGRES:-}" ]]; then
    container="phantom-hot-queries-$$"
    password="phantom-disposable-$$-$RANDOM"
    "${engine[@]}" run -d --name "$container" -p 127.0.0.1::5432 \
        --tmpfs /var/lib/postgresql/data:rw,size=4g \
        -e POSTGRES_USER=phantom_test -e POSTGRES_PASSWORD="$password" \
        -e POSTGRES_DB=phantom_hot_queries_test \
        docker.io/library/postgres:16-alpine >/dev/null
    ready=0
    for attempt in {1..60}; do
        if "${engine[@]}" exec "$container" pg_isready -U phantom_test -d phantom_hot_queries_test >/dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    if [[ "$ready" != 1 ]]; then "${engine[@]}" logs "$container"; exit 1; fi
    address="$("${engine[@]}" port "$container" 5432/tcp)"
    export PHANTOM_TEST_POSTGRES="Host=127.0.0.1;Port=${address##*:};Username=phantom_test;Password=$password;Database=phantom_hot_queries_test"
fi
dotnet build "$project" --configuration Release --disable-build-servers -m:1
dotnet "$root/tests/Jellyfin.Postgres.Tests/bin/Release/net9.0/Jellyfin.Postgres.Tests.dll"
