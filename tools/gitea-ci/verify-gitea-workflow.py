#!/usr/bin/env python3
"""Regression check for the patched-Jellyfin fork's Gitea Actions image pipeline.

Toolchain-agnostic: needs only python3 + PyYAML — no .NET, no podman, no Gitea
runner. It is the in-repo guard that keeps .gitea/workflows/jellyfin-image-build.yml
+ the reused tools/zuul-ci/ scripts from silently rotting, and is the executable
definition-of-done for the `gitea-actions-image-workflow` task (successor to the
retired zuul-ci verify-zuul-config.py).

FAILS without the workflow (the file does not exist / omits a required property)
and PASSES with it — a genuine regression test, not a source-grep.

What it enforces (see docs/tasks/gitea-actions-image-workflow.md for rationale):
  * .gitea/workflows/jellyfin-image-build.yml parses as YAML;
  * it triggers on push (tracked branch) AND pull_request;
  * a `verify` job runs in a CONTAINER whose image is the pinned .NET SDK 9
    (never a host SDK) and runs BOTH patch-apply-verify.sh and build-verify.sh;
  * an `image` job depends on `verify`, runs in a podman/buildah CONTAINER, runs
    image-build.sh, and has a publish step gated on the push event that pushes to
    BOTH git.spencerharmon.com/images/jellyfin-phantom (new, ROI-driven namespace —
    patched-image-oci-namespace-images-migrate) and git.spencerharmon.com/zuul/
    jellyfin-phantom (legacy namespace, kept alongside during migration), and NEVER
    uses a ':latest' tag on either;
  * the three reused CI scripts exist, are executable, and pass `bash -n`.

Exit 0 = all checks pass; 1 = a check failed; 2 = unable to run (missing dep).
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOW = os.path.join(REPO_ROOT, ".gitea", "workflows", "jellyfin-image-build.yml")
TOOLS_CI = os.path.join(REPO_ROOT, "tools", "zuul-ci")

REGISTRY_REF = "git.spencerharmon.com/images/jellyfin-phantom"
LEGACY_REGISTRY_REF = "git.spencerharmon.com/zuul/jellyfin-phantom"
SDK_IMAGE_HINT = "dotnet/sdk:9"
PODMAN_IMAGE_HINTS = ("podman", "buildah")
REQUIRED_SCRIPTS = (
    "patch-apply-verify.sh",
    "build-verify.sh",
    "image-build.sh",
)

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "verify-gitea-workflow: PyYAML is required "
        "(pip install pyyaml / apt install python3-yaml)\n"
    )
    sys.exit(2)

_failures: list[str] = []
_checks = 0


def check(cond: bool, msg: str) -> None:
    global _checks
    _checks += 1
    if not cond:
        _failures.append(msg)


def _job_steps_text(job: dict) -> str:
    """Flatten all `run:` and `uses:` text of a job's steps."""
    parts = []
    for step in job.get("steps", []) or []:
        if not isinstance(step, dict):
            continue
        for key in ("run", "uses", "name"):
            v = step.get(key)
            if isinstance(v, str):
                parts.append(v)
        # env values can carry the tag ref / :latest
        env = step.get("env")
        if isinstance(env, dict):
            parts.extend(str(v) for v in env.values())
        if "if" in step:
            parts.append("__if__:" + str(step["if"]))
    return "\n".join(parts)


def main() -> int:
    check(os.path.isfile(WORKFLOW), f"workflow missing: {WORKFLOW}")
    if not os.path.isfile(WORKFLOW):
        _report()
        return 1

    with open(WORKFLOW, encoding="utf-8") as fh:
        raw = fh.read()
    try:
        # `on:` is the YAML boolean-ish key True after parse — that's fine, we
        # inspect the parsed structure and also the raw text.
        wf = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        check(False, f"workflow does not parse as YAML: {exc}")
        _report()
        return 1
    check(isinstance(wf, dict), "workflow root is not a mapping")

    # --- triggers -----------------------------------------------------------
    on = wf.get("on", wf.get(True))
    check(isinstance(on, dict), "`on:` triggers missing or not a mapping")
    if isinstance(on, dict):
        check("push" in on, "`on.push` trigger missing (publish path)")
        check("pull_request" in on, "`on.pull_request` trigger missing (check path)")
        push = on.get("push") or {}
        branches = (push.get("branches") if isinstance(push, dict) else None) or []
        check(
            any("patch-base-10.11.9" in str(b) for b in branches),
            "`on.push.branches` does not target the tracked branch "
            "phantom-library/patch-base-10.11.9",
        )

    jobs = wf.get("jobs") or {}
    check(isinstance(jobs, dict) and bool(jobs), "no jobs defined")

    # --- verify job: pinned .NET SDK 9 container + both CI check scripts -----
    verify = jobs.get("verify") if isinstance(jobs, dict) else None
    check(isinstance(verify, dict), "`verify` job missing")
    if isinstance(verify, dict):
        container = verify.get("container")
        img = container.get("image") if isinstance(container, dict) else container
        check(
            isinstance(img, str) and SDK_IMAGE_HINT in img,
            f"`verify` job must run in a container whose image is the pinned "
            f".NET SDK 9 (got {img!r}) — the toolchain must not be host-installed",
        )
        text = _job_steps_text(verify)
        check(
            "patch-apply-verify.sh" in text,
            "`verify` job does not run tools/zuul-ci/patch-apply-verify.sh",
        )
        check(
            "build-verify.sh" in text,
            "`verify` job does not run tools/zuul-ci/build-verify.sh",
        )

    # --- image job: podman/buildah container, image-build.sh, gated publish --
    image = jobs.get("image") if isinstance(jobs, dict) else None
    check(isinstance(image, dict), "`image` job missing")
    if isinstance(image, dict):
        needs = image.get("needs")
        needs_list = [needs] if isinstance(needs, str) else (needs or [])
        check("verify" in needs_list, "`image` job must `needs: verify`")
        container = image.get("container")
        img = container.get("image") if isinstance(container, dict) else container
        check(
            isinstance(img, str) and any(h in img for h in PODMAN_IMAGE_HINTS),
            f"`image` job must run in a podman/buildah container (got {img!r}) — "
            f"the container engine must not be host-installed",
        )
        text = _job_steps_text(image)
        check(
            "image-build.sh" in text,
            "`image` job does not run tools/zuul-ci/image-build.sh",
        )
        # publish step: gated on push, pushes to both the new `images/` ref and
        # the legacy `zuul/` ref (the refs are carried in job/workflow env
        # IMAGE_REPO / LEGACY_IMAGE_REPO, so match the raw file)
        check(
            REGISTRY_REF in raw,
            f"workflow does not publish to {REGISTRY_REF}",
        )
        check(
            LEGACY_REGISTRY_REF in raw,
            f"workflow does not publish to {LEGACY_REGISTRY_REF} (legacy namespace "
            f"must stay published alongside the new one during migration)",
        )
        check(
            "github.event_name == 'push'" in text
            or "github.event_name==\"push\"" in text,
            "the publish step is not gated on the push event "
            "(must never publish on a PR)",
        )

    # --- NEVER :latest (whole-workflow invariant) ---------------------------
    check(
        not re.search(r"jellyfin-phantom:latest\b", raw),
        "workflow publishes a ':latest' tag — forbidden (must be a "
        "digest-addressable git-sha tag)",
    )

    # --- reused CI scripts exist, executable, syntactically valid -----------
    for name in REQUIRED_SCRIPTS:
        path = os.path.join(TOOLS_CI, name)
        exists = os.path.isfile(path)
        check(exists, f"reused CI script missing: tools/zuul-ci/{name}")
        if exists:
            check(
                os.access(path, os.X_OK),
                f"reused CI script not executable: tools/zuul-ci/{name}",
            )
            rc = subprocess.run(
                ["bash", "-n", path],
                capture_output=True,
                text=True,
            )
            check(
                rc.returncode == 0,
                f"reused CI script fails `bash -n`: tools/zuul-ci/{name}: "
                f"{rc.stderr.strip()}",
            )

    _report()
    return 1 if _failures else 0


def _report() -> None:
    if _failures:
        sys.stderr.write("\nverify-gitea-workflow: FAILED\n")
        for f in _failures:
            sys.stderr.write(f"  - {f}\n")
        sys.stderr.write(f"\n{len(_failures)} failure(s), {_checks} check(s) run\n")
    else:
        sys.stdout.write(
            f"verify-gitea-workflow: OK — {_checks} check(s) passed\n"
        )


if __name__ == "__main__":
    sys.exit(main())
