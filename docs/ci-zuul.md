# CI on self-hosted Zuul — patched-Jellyfin fork

This fork's CI runs on the swarm's **self-hosted Zuul** (deployed into the cluster by the
`flux` submodule's `zuul` task), not (only) on GitHub Actions. This document is the
`zuul-ci` task deliverable: what the Zuul config does, why it is gated the way it is, the
GitHub-Actions → Zuul migration, and the cross-repo work still pending.

## What runs

In-repo Zuul config lives at the root `.zuul.yaml` + `playbooks/`, with the real logic in
`tools/zuul-ci/` so a developer runs the exact same gates locally. (Converted from
`zuul.d/{jobs,project}.yaml` to a single `.zuul.yaml` by `zuul-image-build-publish`,
2026-07-22 — matches the tenant's own comment and gostream's identical, already-landed shape.)

| Job | Playbook / parent | Script | What it proves |
|-----|--------------------|--------|----------------|
| `jellyfin-patch-apply` | `playbooks/jellyfin-patch-apply.yaml` | `tools/zuul-ci/patch-apply-verify.sh` | the additive channel-refresh patch applies **idempotently** at base tag `v10.11.9` and **fails loud** on any non-applying hunk |
| `jellyfin-build-verify` | `playbooks/jellyfin-build-verify.yaml` | `tools/zuul-ci/build-verify.sh` | the fork builds and the four named DLLs expose the **real** patch surfaces |
| `jellyfin-image-build-check` | `playbooks/jellyfin-image-build.yaml` | `tools/zuul-ci/image-build.sh` | `Dockerfile` (the deployable image) still builds (no push) |
| `jellyfin-image-build` | `parent: build-and-publish-image` (flux base job) | (inherited) | **builds AND publishes** the image to `git.spencerharmon.com/zuul/jellyfin-phantom:<tag>` (registry-served digest) |

All four are attached to the tenant's **`post`** pipeline in the `project:` stanza of
`.zuul.yaml`. `check`/`gate` were **deleted tenant-wide** (ROI reconcile "Zuul goes
Gitea-only" / the GitHub-source follow-up) — the `git`-driver GitHub connection this
project loads from (`ref-updated` polling only, no PR/change events, no reporter) can only
ever drive `post`-style jobs anyway. This fork is an **untrusted project** on that Zuul, so
the config only *attaches* jobs to a pipeline flux's config-project already defines — it
never declares a `pipeline:` of its own and never sets `name:` (it defaults to this repo).
This mirrors the beehive submodule's `release-verify` wiring and gostream's identical,
already-landed `.zuul.yaml`.

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

### `jellyfin-image-build-check` — build only

Builds `Dockerfile` (`git.spencerharmon.com/zuul/jellyfin-phantom`'s recipe) with podman
or docker to prove it still builds, with no push. The real publish is the separate
`jellyfin-image-build` job below (mirrors gostream's `gostream-image-build-check` /
`gostream-image-build` split).

### `jellyfin-image-build` — REAL build + publish

`parent: build-and-publish-image` — flux's reusable base job (`spencerharmon/zuul-config`
gitea config-project's seeded `jobs.yaml`), which runs on the Nodepool `buildah-pod`
static node (label `pod-buildah`), buildah-logs into the Gitea OCI registry from the
k8s Secret `gitea-registry-push` (ns `zuul`), builds this repo's `Dockerfile`, pushes
`git.spencerharmon.com/zuul/jellyfin-phantom:<tag>`, and returns the registry-served
digest as a Zuul job return value. This project supplies only
`vars: {image_name: jellyfin-phantom, image_context: ., containerfile: Dockerfile}` — no
`run:` playbook or `nodeset:` of its own (both inherited). See
`submodules/jellyfin/ARTIFACTS.md`'s "Image build + publish pipeline" section for the full
pipeline detail, verification command, and live-effect status.

## Honest gating — no faked green

`jellyfin-patch-apply` / `jellyfin-build-verify` / `jellyfin-image-build-check` each open
with a **localhost guard** that FAILS the job when the inventory has no build node — a
missing/unsuitable node yields an **honest red**, never a play that matches zero hosts and
silently reports success. flux's Nodepool provider now exists (`nodepool-launcher` +
`zuul-build-node`), but it serves only the buildah-only `pod-buildah` label — no
general-purpose node with git or the .NET 9 SDK — so these three jobs stay honestly red
until such a node is added. `jellyfin-image-build` needs only buildah, so it (uniquely)
CAN run for real today via the `buildah-pod` node it inherits from
`build-and-publish-image`.

`nodeset:` is deliberately **omitted** from the three non-inheriting jobs (each would
otherwise have to guess at a general-purpose label that does not exist yet). Hardcoding
one now would be an unconfirmed guess.

## Cross-repo prerequisite (flux side) — RESOLVED 2026-07-22

`spencerharmon/jellyfin` is now registered as a **GitHub-source untrusted-project** in the
live tenant (`tenant-config.yaml`'s `github:` source, `include-branches:
[phantom-library/patch-base-10.11.9]`), and flux's `build-and-publish-image` base job +
`gitea-registry-push` credential Secret both exist. Confirmed live via
`GET https://zuul.spencerharmon.com/api/tenant/beehive/projects` after forcing
`kubectl -n zuul exec deploy/zuul-scheduler -- zuul-scheduler full-reconfigure` (the
mounted `zuul-tenant-config` ConfigMap had already changed, but the running scheduler was
still serving a stale ZooKeeper-cached system config — a plain pod restart alone did not
pick it up; the online `full-reconfigure` command did). This was the ACTIVE-convergence
remediation this task's card called for, performed in-pass.

## GitHub Actions → Zuul migration

Upstream Jellyfin's workflows under `.github/workflows/` (notably `ci-tests.yml` =
`dotnet test Jellyfin.sln`, `ci-compat.yml` = ABI build/compare, `ci-openapi.yml`,
`ci-codeql-analysis.yml`) are **left in place**. They test generic upstream behaviour;
the Zuul jobs here add the **fork-specific** contract upstream CI does not know about:
the additive patch applies idempotently at the base, the four patched DLLs expose the
real surfaces, and the deployable image builds+publishes. Per the task, GHA is **not**
deleted in a big-bang — cut over (prune the now-redundant workflows) as a **follow-up**
once a general-purpose Nodepool node makes `jellyfin-patch-apply`/`jellyfin-build-verify`
real, not before.

## Reproduce locally

The toolchain-agnostic regression check needs only `python3` + PyYAML:

```
python3 tools/zuul-ci/verify-zuul-config.py
```

It parses `.zuul.yaml`/`playbooks/` YAML, enforces the untrusted-project rules (`post`
only, no `pipeline:`, no `name:`, no `nodeset:` on the three non-inheriting jobs), enforces
each script's contract, runs `bash -n` on the scripts, and runs each gate script in
**dry-run** mode (`JELLYFIN_CI_DRYRUN=1`) — which for `patch-apply-verify.sh` really
applies the patch to a locally-materialized base and checks idempotency + byte-identity
(only the upstream-tag network check and the heavy .NET/image builds are skipped).

Run an individual gate in dry-run:

```
JELLYFIN_CI_DRYRUN=1 tools/zuul-ci/patch-apply-verify.sh
JELLYFIN_CI_DRYRUN=1 tools/zuul-ci/build-verify.sh
JELLYFIN_CI_DRYRUN=1 tools/zuul-ci/image-build.sh
```

If `yamllint` is available (it is not required and may be absent locally):

```
yamllint -c .yamllint .zuul.yaml playbooks
```

On a real build node (with git / the .NET 9 SDK / podman) drop `JELLYFIN_CI_DRYRUN` to run
the full `jellyfin-patch-apply`/`jellyfin-build-verify`/`jellyfin-image-build-check` gates
for real — exactly what Zuul does once a general-purpose Nodepool node is assigned.
`jellyfin-image-build` (the real build+publish job) already runs today on the existing
`buildah-pod` node.

## Poll-driver retrigger — why `jellyfin-image-build` never fired (2026-07-24)

`jellyfin-image-build` is a `post`-pipeline job on the **poll-based `git`-driver** GitHub
connection (`ref-updated` on ref deltas only — no PR/change events, no reporter, no
enqueue REST/webclient). That driver fires `ref-updated` **only for a ref value it observes
*change* after the scheduler started watching**. The commit that merged the correct
`.zuul.yaml` (and the whole `zuul-image-build-publish` config) landed on the tracked branch
`phantom-library/patch-base-10.11.9` **before** the current scheduler began polling (or
before its first `full-reconfigure` loaded the project), so that sha was already in the
driver's baseline and the job **never enqueued once** — confirmed 2026-07-24 by flux's
`phantom-library-bluegreen-repin-gitea-images`:

- `GET /api/tenant/beehive/builds?job_name=jellyfin-image-build` → `[]` (never ran).
- `git.spencerharmon.com/v2/zuul/jellyfin-phantom/tags/list` → HTTP 404 (no package), while
  the sibling `.../v2/zuul/gostream/tags/list` → `{"tags":["da6ee69f8b79"]}` (the base job /
  Nodepool / registry-push plumbing all genuinely work).

Manual re-enqueue is **not** available on this deployment: `zuul enqueue-ref` needs a
`[webclient]` section (absent) and the `/api/tenant/beehive/project/<p>/enqueue` REST
endpoint 404s with no admin authenticator configured. A scheduler **restart does not help
either** — it re-baselines the poller to the *current* tip, so the already-present sha still
never registers as a delta.

The one reliable trigger is therefore a **genuinely new ref value on the tracked branch**.
This commit is that new ref: when it merges to `phantom-library/patch-base-10.11.9`, the
`git`-driver observes the branch tip change and fires `ref-updated`, enqueuing the `post`
pipeline and running `jellyfin-image-build` for the first time. The `.zuul.yaml` job
definition is **unchanged** (it was already correct — 91/91 `verify-zuul-config.py`); only a
new ref delta was needed.

Post-merge confirmation of the published, pullable image (ref + `Docker-Content-Digest`) is
carried by this task's `Verify-After-Merge:` check and recorded in
`submodules/jellyfin/ARTIFACTS.md` / `INFRASTRUCTURE.md` once Zuul converges — the build
cannot exist during the implementing session because it is gated on this very merge.
