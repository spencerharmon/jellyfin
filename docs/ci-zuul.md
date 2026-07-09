# CI on self-hosted Zuul — patched-Jellyfin fork

This fork's CI runs on the swarm's **self-hosted Zuul** (deployed into the cluster by the
`flux` submodule's `zuul` task), not (only) on GitHub Actions. This document is the
`zuul-ci` task deliverable: what the Zuul config does, why it is gated the way it is, the
GitHub-Actions → Zuul migration, and the cross-repo work still pending.

## What runs

In-repo Zuul config lives at `zuul.d/` + `playbooks/`, with the real logic in `tools/zuul-ci/`
so a developer runs the exact same gates locally:

| Job | Playbook | Script | What it proves |
|-----|----------|--------|----------------|
| `jellyfin-patch-apply` | `playbooks/jellyfin-patch-apply.yaml` | `tools/zuul-ci/patch-apply-verify.sh` | the additive channel-refresh patch applies **idempotently** at base tag `v10.11.9` and **fails loud** on any non-applying hunk |
| `jellyfin-build-verify` | `playbooks/jellyfin-build-verify.yaml` | `tools/zuul-ci/build-verify.sh` | the fork builds and the four named DLLs expose the **real** patch surfaces |
| `jellyfin-image-build` | `playbooks/jellyfin-image-build.yaml` | `tools/zuul-ci/image-build.sh` | `Dockerfile` (the deployable image) still builds (no push) |

All three are attached to flux's existing **`check`** and **`gate`** pipelines in
`zuul.d/project.yaml`. This fork is an **untrusted project** on that Zuul, so the config
only *attaches* jobs to pipelines flux already defines — it never declares a `pipeline:`
of its own and never sets `name:` (it defaults to this repo). This mirrors the beehive
submodule's `release-verify` wiring (the canonical shape) and gostream's `zuul-ci`.

### `jellyfin-patch-apply` — idempotent, fail-loud

Ground truth is `submodules/jellyfin/ARTIFACTS.md` (produced by `patch-contract-verify`):
the tracked branch carries the patch as 4 committed commits on top of base
`v10.11.9` (`e83a7e62f2`), touching exactly 5 files —

- **new:** `MediaBrowser.Controller/Channels/IChannelItemRefresh.cs`,
  `MediaBrowser.Controller/Channels/IChannelItemRefreshManager.cs`,
  `tests/Jellyfin.LiveTv.Tests/Channels/ChannelManagerRefreshTests.cs`
- **modified:** `src/Jellyfin.LiveTv/Channels/ChannelManager.cs`,
  `src/Jellyfin.LiveTv/Extensions/LiveTvServiceCollectionExtensions.cs`

Later commits (deploy assets, the container-image `Dockerfile`) do **not** touch those
5 files, so `git diff <base> HEAD -- <the 5 files>` isolates the channel-refresh patch
regardless of how far the tip has advanced. The gate then:

1. asserts the base SHA is a real ancestor of HEAD;
2. asserts upstream jellyfin's `v10.11.9` tag still resolves to that base SHA (network
   `git ls-remote`; skipped in the dry run);
3. asserts the patch is file-level additive (3 new + 2 modified, **zero**
   deletions/renames);
4. applies the patch to a **pristine** base checkout with `git apply`; a second apply
   must be a **detected no-op** (idempotent), and if the patch neither applies nor is
   already applied it is a **hard failure** — a non-applying hunk is never skipped or
   special-cased;
5. asserts base + patch is **byte-identical** to the fork's own files.

### `jellyfin-build-verify` — the REAL surfaces

`dotnet publish Jellyfin.Server -c Release` then assert the four named DLLs exist and
grep the surfaces `patch-contract-verify` actually built and verified:

- `MediaBrowser.Controller.dll` → `IChannelItemRefresh`, `IChannelItemRefreshManager`
- `Jellyfin.LiveTv.dll` → `IChannelItemRefreshManager`, `RefreshChannelItemAsync`
- `MediaBrowser.Model.dll`, `Jellyfin.Api.dll` → present (stock in this patch)

> **Not asserted: `IItemActionProvider` / `/Items/{itemId}/Actions`.** `ROI.md`,
> `PLAN.md`, and this task's design doc list those as patch surface, but
> `patch-contract-verify` proved by exhaustive diff + build + binary grep that they do
> **not exist anywhere** in the fork — a documentation error carried into the ROI (see
> `ARTIFACTS.md` "Discrepancy"). Asserting a surface that does not exist would fake a
> contract, so this gate asserts the two interfaces that are **real** and leaves the
> discrepancy for operator/reconcile disposition.

### `jellyfin-image-build` — build only

Builds `repo/Dockerfile` (`ghcr.io/spencerharmon/jellyfin-phantom:10.11.9`'s recipe)
with podman or docker to prove it still builds. It does **not** push — publishing to a
registry is the live release path (registry credentials + a tag-triggered pipeline) and
is out of scope for check/gate, mirroring gostream's `gostream-image-build`.

## Honest gating — no faked green (pending Nodepool)

flux hosts Zuul but has **no Nodepool build-node provider deployed yet**. All three jobs
perform a **real** build/verify step and need an executor node (git; the .NET 9 SDK;
podman/docker). Rather than stub them green while no node exists, each playbook opens
with a **localhost guard** that FAILS the job when the inventory has no build node —
a missing node yields an **honest red**, never a play that matches zero hosts and
silently reports success.

`nodeset:` is deliberately **omitted** from every job (each inherits whatever nodeset the
tenant's base job eventually defines). Hardcoding a Nodepool label now would be an
unconfirmed guess; the concrete label ships with flux's Nodepool work.

**Cross-dep (for the next reconcile):** live execution of these jobs depends on flux's
Nodepool provider task. The concrete `flux:<taskid>` is **not invented here** — it does
not exist yet. The next reconcile attaches it to this task's `PLAN.md` deps once flux's
Nodepool task id is known (the authorized jellyfin ↔ flux `SUBMODULE-LINKS.yaml` link
permits that qualified cross-submodule dep). This mirrors gostream's `zuul-ci` +
phantom-library's Nodepool-sentinel pattern.

## Cross-repo prerequisite (flux side, NOT this repo)

For these jobs to load and run in the deployed tenant, **flux** must register
`spencerharmon/jellyfin` under `untrusted-projects` in
`infrastructure/zuul/tenant-config.yaml` (the github-origin projects beehive and gostream
are already registered there and attach to check/gate — jellyfin follows the same
pattern). Tracked via the authorized jellyfin ↔ flux submodule link. Until then the
config is inert on the tenant but fully lints/reproduces locally (below).

## GitHub Actions → Zuul migration

Upstream Jellyfin's workflows under `.github/workflows/` (notably `ci-tests.yml` =
`dotnet test Jellyfin.sln`, `ci-compat.yml` = ABI build/compare, `ci-openapi.yml`,
`ci-codeql-analysis.yml`) are **left in place**. They test generic upstream behaviour;
the Zuul jobs here add the **fork-specific** contract upstream CI does not know about:
the additive patch applies idempotently at the base, the four patched DLLs expose the
real surfaces, and the deployable image builds. Per the task, GHA is **not** deleted in a
big-bang — cut over (prune the now-redundant workflows) as a **follow-up** once Zuul is
proven live with a real Nodepool node, not before.

## Reproduce locally

The toolchain-agnostic regression check needs only `python3` + PyYAML:

```
python3 tools/zuul-ci/verify-zuul-config.py
```

It parses all `zuul.d/`/`playbooks/` YAML, enforces the untrusted-project rules (check/gate
only, no `pipeline:`, no `name:`, no `nodeset:`), enforces each script's contract, runs
`bash -n` on the scripts, and runs each gate script in **dry-run** mode
(`JELLYFIN_CI_DRYRUN=1`) — which for `patch-apply-verify.sh` really applies the patch to a
locally-materialized base and checks idempotency + byte-identity (only the upstream-tag
network check and the heavy .NET/image builds are skipped).

Run an individual gate in dry-run:

```
JELLYFIN_CI_DRYRUN=1 tools/zuul-ci/patch-apply-verify.sh
JELLYFIN_CI_DRYRUN=1 tools/zuul-ci/build-verify.sh
JELLYFIN_CI_DRYRUN=1 tools/zuul-ci/image-build.sh
```

If `yamllint` is available (it is not required and may be absent locally):

```
yamllint -c .yamllint zuul.d playbooks
```

On a real build node (with git / the .NET 9 SDK / podman) drop `JELLYFIN_CI_DRYRUN` to run
the full gates — exactly what Zuul does once a Nodepool node is assigned.
