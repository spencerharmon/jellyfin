# PostgreSQL Hot Queries

## Scope and Measurements

Core query changes only. The pinned JPVenson provider, migrations, model, keys,
image format and write representation are unchanged. Existing indexes suffice:
`ItemValues(Type, Value)`, `BaseItemProviders(ProviderId, ProviderValue, ItemId)`
and `BaseItemImageInfos(ItemId)`.

The executable regression calls the actual `BaseItemRepository.SaveItems`,
`SaveImages`, `GetItemIdsList` and `GetItemList`, using the shipped PostgreSQL
provider and migrations against PostgreSQL 16. It seeds 4,000,000 ItemValues and
20,000 movie/episode items with provider/image rows. A command interceptor clones
typed Npgsql parameters and captures `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`
before execution on the same connection. Writes are explained inside a rolled-back
savepoint, then executed normally by the repository. No planner switches are used.

Full executed statements, parameters, buffers and plans are committed under
`tests/Jellyfin.Postgres.Tests/evidence/{before,after}.json`. The before run uses
the unchanged core and fails the same selective-plan assertion. Evidence is from
an isolated database, not a claim of a live deployment or full HTTP playback test.

| Actual path | Before execution ms | After execution ms | Result |
| --- | ---: | ---: | --- |
| SaveItems value lookup, insert | 1665.709 | 0.068-0.090 per type | Seq Scan replaced by Index Scan |
| SaveItems value lookup, update | 676.057 | 0.044-0.064 per type | Seq Scan replaced by Index Scan |
| Selected provider ID/item lookup | 5.929-11.629 | 0.309-0.512 | Indexed provider selection and hydration |
| SaveImages replacement delete | already indexed | 0.060 | Existing ItemId index retained |

Value lookups now issue one indexed query per distinct value type (four in these
fixtures), instead of converting the indexed type to text and concatenating the
value. Provider selection unions matching item IDs from typed key/value predicates;
multiple pairs remain OR, while provider-name-only and selected-pair groups remain
AND. Exclusion uses exact typed pairs. Delimiters in values no longer obstruct the
index; pairs are treated as pairs rather than ambiguous concatenated strings.

The harness validates movie/episode identity, provider IDs, image metadata,
genres/studios/tags/inherited tags, updates and absence of duplicate mappings.
It gates selective queries on no targeted Seq Scan and execution time below 5ms.
These are database execution times, not network/API/JIT latency. No plugin claim
or poll implementation exists in this core task; its 4M claim regression remains
owned by phantom-library. This test does not substitute for that regression.

## Remaining Hotspots

Broad browse is NOT a sub-5ms poll query. The recorded run measured 19.495ms before
and 30.401ms after for the unchanged movie-page SQL: 10,001 BaseItems read before selecting 20,
then indexed provider/image hydration. Its sorting/distinct work and multi-collection
join remain unchanged; no broad-browse improvement is claimed. Full plans in the
evidence include that query. Image hydration and replacement already use indexes;
adding another image index without evidence would add shared write overhead.
Case-folded provider-presence and broad exclusion searches can legitimately read
many items and are not represented as bounded claim queries here.

## Run and Publish

Run `./scripts/tests/phantom-postgres-hot-queries.test.sh` from this checkout.
It needs .NET 9 and rootless Podman; CI supplies the SDK container and a PostgreSQL
service. Local PostgreSQL data uses a disposable 4GiB tmpfs, with at least that
much free memory required. Reports go to ignored `tests/Jellyfin.Postgres.Tests/artifacts`.
Alternatively `PHANTOM_TEST_POSTGRES` may point to an EMPTY isolated test database:
host localhost/127.0.0.1/postgres, role phantom_test, database phantom_hot_queries_*.
Existing tables are refused; it never drops an existing database. Do not point it
at a deployment or use a forwarded production connection.

The existing Gitea verify job now runs this check before image build/publish.
Reviewed changes publish through the existing SHA-tagged image pipeline on merge
to the tracked branch. Do not publish or promote an unreviewed image as production.
The unchanged provider stays bundled by the existing Dockerfile. No new provider
fork or plugin version/pin is introduced.

## Resume and Roll Back

There is no schema migration to apply, resume, or roll back: no DDL, startup index
build, table rewrite, or contract phase is introduced. Both old and new cores use
the same rows and indexes, so an interrupted inactive-color rollout can resume
from its reviewed image digest; reverting that color to its previous image digest
does not require a data rollback. Never revert shared DB contents to roll back code.

Before rollout, verify existing index definitions and validity in `pg_indexes` and
`pg_index`, then compare actual workload plans. If a deployment is missing an index
the shipped migrations already define, repair it as a separately reviewed additive
operation: `CREATE INDEX CONCURRENTLY` outside transactions, one build at a time.
Do not assume `IF NOT EXISTS` repairs an invalid interrupted index: inspect validity
and exact definition first. No speculative DDL is supplied or run by this change.

Inactive-color deployment, both-color read/write verification, actual movie/episode
playback and shared-server load reduction are post-merge cross-stack checks owned
by `phantom-library:p0-live-load-reduction`. This patch does not flip production,
restart either color, or claim those pending checks passed.
