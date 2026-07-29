#!/usr/bin/env python3
"""Regression check for the patched-Jellyfin fork's Zuul CI config.

Toolchain-agnostic: needs only python3 + PyYAML — no .NET, no upstream clone, no
Zuul executor. It is the in-repo guard that keeps .zuul.yaml + playbooks/ +
tools/zuul-ci/ from silently rotting, and doubles as the local "reproduce now" lint +
dry run required by the zuul-ci task.

What it enforces (see docs/ci-zuul.md for rationale):
  * .zuul.yaml and every playbooks/*.yaml parses as YAML;
  * the project attaches jobs to `post` ONLY (check/gate were deleted
    tenant-wide, see zuul-config's zuul.d/pipelines.yaml), declares no
    `pipeline:` and no `name:` (untrusted-project rules);
  * every job attached to a pipeline is defined; a job with no `parent:` (or a
    `parent` other than a flux base job) declares a run: playbook that exists
    and NO nodeset of its own (no general-purpose Nodepool node yet -> honest
    red); `jellyfin-image-build` (parent: build-and-publish-image) is exempt —
    it inherits its run: playbook + nodeset from flux's base job;
  * each of the three non-inheriting playbooks has the honest empty-inventory
    guard and invokes its script;
  * the three gate scripts exist, are executable, pass `bash -n`, and encode
    their contracts (idempotent fail-loud apply; the four DLLs + REAL surfaces,
    plus the restored IItemActionProvider/ItemAction* surface; Dockerfile build with no push);
  * each script runs clean end-to-end in dry-run mode (exercising control flow +
    the honest checks without a toolchain / network).

Exit 0 = all checks pass; 1 = a check failed; 2 = unable to run (missing dep).
"""
from __future__ import annotations

import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ZUUL_YAML = os.path.join(REPO_ROOT, ".zuul.yaml")
PLAYBOOKS = os.path.join(REPO_ROOT, "playbooks")
TOOLS_CI = os.path.join(REPO_ROOT, "tools", "zuul-ci")

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "verify-zuul-config: PyYAML is required "
        "(pip install pyyaml / apt install python3-yaml)\n"
    )
    sys.exit(2)

_failures: list[str] = []
_checks = 0


def check(cond: bool, msg: str) -> bool:
    global _checks
    _checks += 1
    if not cond:
        _failures.append(msg)
        print(f"  FAIL  {msg}")
    else:
        print(f"  ok    {msg}")
    return bool(cond)


def load_yaml(path: str):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# Expected job -> (run playbook, gate script) wiring. jellyfin-image-build
# inherits its run:/nodeset from parent build-and-publish-image, so it is
# handled separately (INHERITED_JOBS below), not in this dict.
JOBS_EXPECTED = {
    "jellyfin-patch-apply": ("playbooks/jellyfin-patch-apply.yaml", "tools/zuul-ci/patch-apply-verify.sh"),
    "jellyfin-build-verify": ("playbooks/jellyfin-build-verify.yaml", "tools/zuul-ci/build-verify.sh"),
    "jellyfin-image-build-check": ("playbooks/jellyfin-image-build.yaml", "tools/zuul-ci/image-build.sh"),
}
# Jobs that inherit run:/nodeset from a parent job defined elsewhere (flux's
# zuul-config config-project) — this repo supplies only vars:, never a run:
# playbook or nodeset of its own.
INHERITED_JOBS = {"jellyfin-image-build": "build-and-publish-image"}


def main() -> int:
    print("== files present ==")
    check(os.path.isfile(ZUUL_YAML), f"exists: {os.path.relpath(ZUUL_YAML, REPO_ROOT)}")

    print("\n== yaml parses ==")
    yaml_files = [ZUUL_YAML] if os.path.isfile(ZUUL_YAML) else []
    if os.path.isdir(PLAYBOOKS):
        for name in sorted(os.listdir(PLAYBOOKS)):
            if name.endswith((".yaml", ".yml")):
                yaml_files.append(os.path.join(PLAYBOOKS, name))
    for p in yaml_files:
        rel = os.path.relpath(p, REPO_ROOT)
        try:
            load_yaml(p)
            check(True, f"parses: {rel}")
        except Exception as exc:  # noqa: BLE001
            check(False, f"parses: {rel} ({exc})")

    # --- job definitions -----------------------------------------------------
    print("\n== job definitions ==")
    jobs: dict[str, dict] = {}
    if os.path.isfile(ZUUL_YAML):
        for item in load_yaml(ZUUL_YAML) or []:
            if isinstance(item, dict) and "job" in item:
                job = item["job"]
                jobs[job["name"]] = job
    check(bool(jobs), f"at least one job defined ({len(jobs)} found)")
    for name in list(JOBS_EXPECTED) + list(INHERITED_JOBS):
        check(name in jobs, f"expected job defined: {name}")

    for name, job in jobs.items():
        if name in INHERITED_JOBS:
            check(
                job.get("parent") == INHERITED_JOBS[name],
                f"job '{name}' inherits parent: {INHERITED_JOBS[name]}",
            )
            check(
                "run" not in job,
                f"job '{name}' declares no run: of its own (inherits from parent)",
            )
            check(
                "nodeset" not in job,
                f"job '{name}' declares no nodeset of its own (inherits buildah-pod from parent)",
            )
            continue
        check("run" in job, f"job '{name}' has a run: playbook")
        ref = job.get("run")
        refs = (ref if isinstance(ref, list) else [ref]) if ref else []
        for r in refs:
            check(
                os.path.isfile(os.path.join(REPO_ROOT, r)),
                f"job '{name}' run playbook exists: {r}",
            )
        # No general-purpose Nodepool node yet: a hardcoded nodeset would fake a node contract.
        check(
            "nodeset" not in job,
            f"job '{name}' declares no nodeset (no general-purpose Nodepool node yet — honest red)",
        )

    # --- project / pipeline attachment --------------------------------------
    print("\n== project attachment (untrusted-project rules) ==")
    project = None
    if os.path.isfile(ZUUL_YAML):
        for item in load_yaml(ZUUL_YAML) or []:
            if isinstance(item, dict) and "project" in item:
                project = item["project"]
    check(project is not None, "zuul.yaml defines a project stanza")

    if project is not None:
        check("name" not in project, "project omits name: (defaults to this repo)")
        attached: set[str] = set()
        allowed = {"post"}
        pipelines = {k for k in project if k not in ("templates", "vars", "queue")}
        for pl in pipelines:
            check(
                pl in allowed,
                f"project attaches only to post (found pipeline key '{pl}')",
            )
            spec = project.get(pl) or {}
            for j in (spec.get("jobs") or []):
                jn = j if isinstance(j, str) else next(iter(j))
                attached.add(jn)
        for pl in ("post",):
            spec = project.get(pl) or {}
            check(bool(spec.get("jobs")), f"project attaches at least one job to {pl}")
        for jn in attached:
            check(jn in jobs, f"attached job '{jn}' is defined in .zuul.yaml")
        for name in list(JOBS_EXPECTED) + list(INHERITED_JOBS):
            check(name in attached, f"job attached to a pipeline: {name}")

    # No project may define a pipeline of its own (untrusted).
    print("\n== no pipeline definitions (untrusted-project rule) ==")
    for p in yaml_files:
        if p != ZUUL_YAML:
            continue
        for item in load_yaml(p) or []:
            if isinstance(item, dict):
                check(
                    "pipeline" not in item,
                    f"{os.path.relpath(p, REPO_ROOT)} declares no pipeline:",
                )

    # --- playbooks: honesty guard + script wiring ---------------------------
    print("\n== playbooks: honest guard + script wiring ==")
    guard = "groups['all'] | length == 0"
    for name, (pb_rel, script) in JOBS_EXPECTED.items():
        pb = os.path.join(REPO_ROOT, pb_rel)
        if not check(os.path.isfile(pb), f"playbook exists: {pb_rel}"):
            continue
        body = read(pb)
        check(guard in body, f"{pb_rel} has the honest empty-inventory guard")
        check(
            "ansible.builtin.fail" in body,
            f"{pb_rel} fails (red) on the empty inventory",
        )
        check(script in body, f"{pb_rel} invokes {script}")
        check(
            "{{ ansible_user_dir }}/{{ zuul.project.src_dir }}" in body,
            f"{pb_rel} runs inside the Zuul checkout",
        )

    # --- gate scripts: exist, executable, bash -n, contract -----------------
    print("\n== gate scripts present + executable ==")
    scripts = {
        "patch-apply-verify.sh": os.path.join(TOOLS_CI, "patch-apply-verify.sh"),
        "build-verify.sh": os.path.join(TOOLS_CI, "build-verify.sh"),
        "image-build.sh": os.path.join(TOOLS_CI, "image-build.sh"),
    }
    for rel, s in scripts.items():
        check(os.path.isfile(s), f"exists: tools/zuul-ci/{rel}")
        check(os.access(s, os.X_OK), f"executable: tools/zuul-ci/{rel}")

    print("\n== patch-apply contract ==")
    if os.path.isfile(scripts["patch-apply-verify.sh"]):
        b = read(scripts["patch-apply-verify.sh"])
        check("e83a7e62f26443f7dd98f126d6955ac1af090125" in b, "patch-apply pins base SHA e83a7e62f2")
        check("git apply --check" in b, "patch-apply uses `git apply --check` (dry apply)")
        check("-R" in b, "patch-apply checks reverse-apply (idempotent already-applied)")
        check("merge-base --is-ancestor" in b, "patch-apply asserts base is an ancestor of HEAD")
        check("IChannelItemRefresh.cs" in b, "patch-apply names the new interface files")
        check("ChannelManager.cs" in b, "patch-apply names the modified files")
        check("diff-filter=DR" in b or "diff-filter=D" in b, "patch-apply guards against deletions/renames")
        check("byte" in b.lower() and "sha256" in b, "patch-apply asserts byte-identity")
        check("NOT skipping" in b or "fail loud" in b.lower(), "patch-apply fails loud (no skip)")

    print("\n== build/surface contract ==")
    if os.path.isfile(scripts["build-verify.sh"]):
        b = read(scripts["build-verify.sh"])
        check("dotnet publish Jellyfin.Server" in b, "build runs `dotnet publish Jellyfin.Server`")
        for dll in (
            "MediaBrowser.Controller.dll",
            "MediaBrowser.Model.dll",
            "Jellyfin.Api.dll",
            "Jellyfin.LiveTv.dll",
        ):
            check(dll in b, f"build asserts DLL present: {dll}")
        for sym in ("IChannelItemRefresh", "IChannelItemRefreshManager", "RefreshChannelItemAsync"):
            check(sym in b, f"build asserts REAL surface: {sym}")
        for sym in ("IItemActionProvider", "ItemActionInfo", "ItemActionRequest", "ItemActionResult", "ItemActionsController"):
            check(sym in b, f"build asserts RESTORED item-action surface: {sym}")
        check(
            "ITEM-ACTION SURFACE RESTORED" in b,
            "build documents that the item-action surface was restored (plugin 0.3.0.0 needs it)",
        )
        check("grep -aq" in b, "build greps the built DLLs for the surfaces")

    print("\n== image-build contract ==")
    if os.path.isfile(scripts["image-build.sh"]):
        b = read(scripts["image-build.sh"])
        check("Dockerfile" in b, "image-build references the Dockerfile")
        check("podman" in b and "docker" in b, "image-build supports podman/docker")
        check("no push" in b.lower() or "never pushed" in b.lower(), "image-build does not push")

    # --- bash -n syntax ------------------------------------------------------
    print("\n== bash -n syntax ==")
    have_bash = subprocess.run(["bash", "-c", "true"], capture_output=True).returncode == 0
    if have_bash:
        for rel, s in scripts.items():
            if not os.path.isfile(s):
                continue
            r = subprocess.run(["bash", "-n", s], capture_output=True, text=True)
            check(
                r.returncode == 0,
                f"bash -n tools/zuul-ci/{rel}" + (f" :: {r.stderr.strip()}" if r.returncode else ""),
            )
    else:
        print("  skip  bash not available")

    # --- toolchain-agnostic dry runs ----------------------------------------
    print("\n== toolchain-agnostic dry runs ==")
    if have_bash:
        env = dict(os.environ, JELLYFIN_CI_DRYRUN="1")
        for rel, s in scripts.items():
            if not os.path.isfile(s):
                continue
            r = subprocess.run([s], capture_output=True, text=True, env=env)
            ok = check(r.returncode == 0, f"dry run exits 0: tools/zuul-ci/{rel}")
            out = r.stdout + r.stderr
            check("PASSED" in out, f"dry run reaches PASSED: tools/zuul-ci/{rel}")
            if not ok:
                print(out)
    else:
        print("  skip  bash unavailable")

    print(f"\n{'=' * 48}")
    if _failures:
        print(f"FAILED: {len(_failures)}/{_checks} checks failed")
        for f in _failures:
            print(f"  - {f}")
        return 1
    print(f"OK: all {_checks} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
