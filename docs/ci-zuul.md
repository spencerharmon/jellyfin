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
| `jellyfin-image-build-publish` | (inherited from `build-and-publish-image`) | (buildah, no local script) | **BUILDS AND PUBLISHES** `git.spencerharmon.com/zuul/jellyfin-phantom:<tag>` to the in-cluster Gitea OCI registry — task `zuul-image-build-publish`, 2026-07-21 |

**Pipeline reality update (2026-07-21):** all four are attached to **`post`** only in
`zuul.d/project.yaml`. This originally targeted flux's `check`/`gate` pipelines, but those were
deleted **tenant-wide** by flux's Gitea-only migration (ROI reconcile d09b7e14e1, flux commit
`cc8c47b` "Zuul goes Gitea-only") — confirmed live against the deployed scheduler
(`GET /api/tenant/beehive/...` lists exactly one pipeline, `post`; the `gitea` git-driver
connection has only `ref-updated` events, no PR/change events, no reporter). Attaching to a
nonexistent pipeline is a hard tenant-config-load error that would break every project in the
tenant, not just this one. This fork is still an **untrusted project** on that Zuul — the config
only *attaches* jobs to a pipeline the trusted `spencerharmon/zuul-config` config-project
defines; it never declares a `pipeline:` of its own and never sets `name:` (it defaults to this
repo). A future native Gitea-driver upgrade may reintroduce check/gate; re-split these jobs onto
it then.

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

Builds `repo/Dockerfile` with podman or docker to prove it still builds. It does **not**
push — see `jellyfin-image-build-publish` below for the job that does.

### `jellyfin-image-build-publish` — build AND publish (task `zuul-image-build-publish`, 2026-07-21)

Inherits `build-and-publish-image` from the trusted `spencerharmon/zuul-config` config-project
(also stood up by this task: the base job + its `gitea_registry_push` secret + its
`playbooks/build-and-publish-image.yaml` run playbook did not exist before). Runs on the
Nodepool **`buildah-pod`** static build node (the one real Nodepool provider flux has deployed —
`docs/tasks/zuul-nodepool-provider.md`), builds `repo/Dockerfile` with `buildah bud`, and pushes
the result to the in-cluster Gitea OCI registry as
`git.spencerharmon.com/zuul/jellyfin-phantom:<tag>` — **never `:latest`**. The playbook return-
values the registry-served digest so a consumer (flux's `phantom-library-bluegreen-deploy`) can
pin by digest. See `docs/runbooks/build-image-in-gitea.md` in the flux submodule for the shared
recipe this follows, and `submodules/jellyfin/ARTIFACTS.md`'s "Container image" section for the
canonical published ref (which **supersedes** the never-pullable
`ghcr.io/spencerharmon/jellyfin-phantom:10.11.9` placeholder).

## Honest gating — no faked green (pending Nodepool, for the three non-publish jobs)

`jellyfin-patch-apply`, `jellyfin-build-verify`, and `jellyfin-image-build` still perform a
**real** build/verify step and need an executor node (git; the .NET 9 SDK; podman/docker) that
no Nodepool label currently targets. Rather than stub them green, each playbook opens with a
**localhost guard** that FAILS the job when the inventory has no build node — a missing node
yields an **honest red**, never a play that matches zero hosts and silently reports success.
`nodeset:` is deliberately **omitted** from these three (each inherits whatever nodeset the
tenant's base job eventually defines for them). `jellyfin-image-build-publish` is different: it
DOES have a real Nodepool node today (the `buildah-pod` nodeset via its parent job), so it both
builds and publishes on every push.

**Cross-dep (for the next reconcile) — Nodepool label for the three non-publish jobs:** a
hardcoded nodeset for `jellyfin-patch-apply`/`jellyfin-build-verify`/`jellyfin-image-build` would
still be an unconfirmed guess beyond the one `buildah-pod` label that exists; the concrete labels
ship with any future flux Nodepool expansion. The `flux:<taskid>` for that expansion is **not
invented here** — it does not exist yet. This mirrors gostream's `zuul-ci` + phantom-library's
Nodepool-sentinel pattern.

## Cross-repo prerequisite (flux side, NOT this repo) — the actual remaining blocker

None of these four jobs actually **run** yet: `spencerharmon/jellyfin` is not yet registered
under `untrusted-projects` in flux's GitOps-tracked `infrastructure/zuul/tenant-config.yaml`
(confirmed live — the deployed `zuul-tenant-config` ConfigMap currently lists only
`spencerharmon/flux`, `spencerharmon/helm-charts`, `spencerharmon/beehive`). That ConfigMap is
flux's own Kustomization-managed resource; editing it live without a corresponding flux-tracked
git commit would drift and get reverted on the next flux reconcile, so it is **not** done from
this submodule's worktree. flux's tracked `PLAN.md` has not yet landed a task id for this at this
reconcile, so the real `flux:<taskid>` dep is a documented note for the next reconcile to attach
(mirrors the Nodepool-label note above) — never a fabricated peer id or local sentinel. Until it
lands, the config here is inert on the tenant but fully lints/reproduces locally (below), and the
`build-and-publish-image` base job + `gitea_registry_push` secret this task added to
`spencerharmon/zuul-config` are live and loaded tenant-wide (verified: `GET
/api/tenant/beehive/jobs` lists `build-and-publish-image` with zero config-load errors).

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

It parses all `zuul.d/`/`playbooks/` YAML, enforces the untrusted-project rules (attaches only to
`post`, no `pipeline:`, no `name:`, no `nodeset:` on the three non-publish jobs), enforces each script's contract, runs
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
