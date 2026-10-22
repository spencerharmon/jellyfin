"""Offline registry responses exercise the same entry point used by the shell probe."""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

import jellyfin_phantom_plugin_content_probe as probe


DLL = "opt/jellyfin/plugins-preload/Jellyfin.Plugin.PhantomLibrary/Jellyfin.Plugin.PhantomLibrary.dll"
VERSION = "0.5.7.7"
SOURCE_REF = "d9a58ece9e7111f86663efe0c608147c099205a3"
METRIC = "phantom_playback_outcome_total"
METHOD = "SeedPlaybackOutcomes"
LITERAL = "Phantom OTLP runtime provenance:"


def sha(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def layer(entries):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as archive:
        for name, content in entries.items():
            member = tarfile.TarInfo(name)
            if content is None:
                member.type = tarfile.SYMTYPE
                member.linkname = "elsewhere"
                archive.addfile(member)
            else:
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
    return data.getvalue()


def dll(version=VERSION, source_ref=SOURCE_REF, method=METHOD, literal=LITERAL):
    informational = (version + "+" + source_ref).encode()
    return (b"MZ\0" + bytes([len(informational)]) + informational + b"\0"
            + method.encode() + b"\0" + METRIC.encode("utf-16-le") + b"\0\0"
            + literal.encode("utf-16-le"))


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.cfg = dict(host="registry.example.com", repo="images/plugin", tag="0123456789ab",
                        token="test-token", dll_suffix=DLL, metric=METRIC, version=VERSION,
                        source_ref=SOURCE_REF, method=METHOD, runtime_literal=LITERAL)
        self.base = "https://registry.example.com/v2/images/plugin"
        self.responses = {}
        self.requests = []

    def image(self, layers, index=False):
        for blob in layers:
            self.responses["/blobs/" + sha(blob)] = (blob, {})
        manifest = json.dumps({"schemaVersion": 2, "layers": [
            {"digest": sha(blob), "size": len(blob)} for blob in layers]}).encode()
        if index:
            self.responses["/manifests/" + sha(manifest)] = (manifest, {})
            manifest = json.dumps({"manifests": [{"digest": sha(manifest),
                                  "platform": {"os": "linux", "architecture": "amd64"}}]}).encode()
        self.responses["/manifests/" + self.cfg["tag"]] = (
            manifest, {"Docker-Content-Digest": sha(manifest)})
        return sha(manifest)

    def urlopen(self, request, timeout):
        self.assertEqual(timeout, 120)
        self.assertEqual(request.get_header("Authorization"), "Bearer test-token")
        self.assertTrue(request.full_url.startswith(self.base))
        path = request.full_url[len(self.base):]
        self.requests.append(path)
        if path not in self.responses:
            raise urllib.error.HTTPError(request.full_url, 404, "missing", {}, None)
        data, headers = self.responses[path]
        response = io.BytesIO(data)
        response.headers = headers
        return response

    def run_probe(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(probe.urllib.request, "urlopen", side_effect=self.urlopen), \
                patch.object(sys, "stdin", io.StringIO(json.dumps(self.cfg))), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            rc = probe.main()
        return rc, stdout.getvalue(), stderr.getvalue()

    def test_success_reports_top_digest_dll_digest_and_expectations(self):
        for index in (False, True):
            with self.subTest(index=index):
                digest = self.image([layer({DLL: dll()})], index=index)
                rc, out, err = self.run_probe()
                self.assertEqual((rc, err), (0, ""))
                self.assertIn("manifest_digest=" + digest, out)
                self.assertIn("plugin_dll_sha256=" + hashlib.sha256(dll()).hexdigest(), out)
                for expected in (VERSION, SOURCE_REF, METHOD, LITERAL, METRIC):
                    self.assertIn(expected, out)

    def test_old_metric_only_rejected_but_legacy_mode_preserved(self):
        for encoding in ("ascii", "utf-16-le"):
            with self.subTest(encoding=encoding):
                self.image([layer({DLL: METRIC.encode(encoding)})])
                self.assertEqual(self.run_probe()[0], 1)
        for key in ("version", "source_ref", "method", "runtime_literal"):
            self.cfg.pop(key)
        for encoding in ("ascii", "utf-16-le"):
            with self.subTest(legacy_encoding=encoding):
                self.image([layer({DLL: METRIC.encode(encoding)})])
                self.assertEqual(self.run_probe()[0], 0)

    def test_wrong_version_ref_or_required_marker_rejected(self):
        cases = [dict(version="0.5.7.6"), dict(version="0.5.7.70"),
                 dict(version="10.5.7.7"),
                 dict(source_ref="a" * 40), dict(source_ref=SOURCE_REF[:12]),
                 dict(source_ref=SOURCE_REF + "a"), dict(method=""), dict(literal="")]
        for changes in cases:
            with self.subTest(changes=changes):
                self.image([layer({DLL: dll(**changes)})])
                self.assertEqual(self.run_probe()[0], 1)

    def test_version_only_accepts_serialized_informational_version(self):
        self.cfg.pop("source_ref")
        self.image([layer({DLL: dll()})])
        self.assertEqual(self.run_probe()[0], 0)

    def test_required_marker_encodings(self):
        for content in (dll(method="") + METHOD.encode("utf-16-le"),
                        dll(literal="") + LITERAL.encode("ascii")):
            with self.subTest(content=content):
                self.image([layer({DLL: content})])
                self.assertEqual(self.run_probe()[0], 1)

    def test_missing_image(self):
        rc, _, err = self.run_probe()
        self.assertEqual(rc, 3)
        self.assertIn("manifest not yet available", err)

    def test_digest_mismatch_manifest_child_and_blob(self):
        for kind in ("top", "child", "blob"):
            with self.subTest(kind=kind):
                self.responses.clear()
                self.image([layer({DLL: dll()})], index=True)
                path = next(p for p in self.responses if
                            (p == "/manifests/" + self.cfg["tag"] if kind == "top" else
                             p.startswith("/manifests/sha256:" if kind == "child" else "/blobs/")))
                data, headers = self.responses[path]
                self.responses[path] = (data + b" ", headers)
                rc, _, err = self.run_probe()
                self.assertEqual(rc, 1)
                self.assertIn("digest mismatch", err)

    def test_missing_registry_digest_rejected(self):
        self.image([layer({DLL: dll()})])
        path = "/manifests/" + self.cfg["tag"]
        self.responses[path] = (self.responses[path][0], {})
        self.assertIn("omitted top-level", self.run_probe()[2])

    def test_missing_or_invalid_newer_layer_never_falls_back(self):
        old = layer({DLL: dll()})
        new = layer({"unrelated": b"data"})
        for invalid in (None, b"not a tar archive"):
            with self.subTest(invalid=invalid):
                self.image([old, new if invalid is None else invalid])
                if invalid is None:
                    del self.responses["/blobs/" + sha(new)]
                self.requests.clear()
                self.assertEqual(self.run_probe()[0], 1)
                self.assertNotIn("/blobs/" + sha(old), self.requests)

    def test_whiteouts_hide_old_dll(self):
        target = Path(DLL)
        markers = [str(p.parent / (".wh." + p.name)) for p in [target, *target.parents] if p.name]
        markers += [str(p / ".wh..wh..opq") for p in target.parents]
        for marker in markers:
            with self.subTest(marker=marker):
                old = layer({DLL: dll()})
                self.image([old, layer({"./" + marker: b""})])
                self.requests.clear()
                rc, _, err = self.run_probe()
                self.assertEqual(rc, 1)
                self.assertIn("whiteout", err)
                self.assertNotIn("/blobs/" + sha(old), self.requests)

    def test_same_layer_replacement_survives_whiteout(self):
        marker = str(Path(DLL).parent / ".wh..wh..opq")
        self.image([layer({DLL: b"old"}), layer({marker: b"", "./" + DLL: dll()})])
        self.assertEqual(self.run_probe()[0], 0)

    def test_missing_dll(self):
        self.image([layer({"unrelated": b"data"})])
        self.assertIn("DLL not found", self.run_probe()[2])

    def test_newer_stale_or_nonregular_dll_and_parent_never_fall_back(self):
        for entries in ({DLL: b"stale"}, {DLL: None}, {str(Path(DLL).parent): None}):
            with self.subTest(entries=entries):
                self.image([layer({DLL: dll()}), layer(entries)])
                self.assertEqual(self.run_probe()[0], 1)

    def test_wrong_path_suffix_does_not_count(self):
        self.image([layer({"stale-copy/" + DLL: dll()})])
        self.assertEqual(self.run_probe()[0], 1)


class WrapperTests(unittest.TestCase):
    wrapper = Path(__file__).with_name("jellyfin-phantom-zero-seed-probe.test.sh")

    def test_requires_explicit_full_sha(self):
        for args in ([], ["a" * 12], ["z" * 40], ["a" * 40, "extra"]):
            with self.subTest(args=args):
                result = subprocess.run([str(self.wrapper), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn("FULL_FORK_SHA", result.stderr)

    def test_fixed_expectations_tag_timeout_and_exit_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = Path(tmp) / self.wrapper.name
            shutil.copy2(self.wrapper, wrapper)
            delegate = Path(tmp) / "jellyfin-phantom-plugin-content-probe.test.sh"
            delegate.write_text("#!" + sys.executable + "\nimport json, os, sys\n"
                                "print(json.dumps(dict(os.environ), sort_keys=True))\n"
                                "print('tag=' + sys.argv[1])\nsys.exit(1)\n")
            delegate.chmod(0o755)
            for timeout in (None, "10"):
                env = {k: v for k, v in os.environ.items() if not k.startswith("PHANTOM_")}
                env.update(PHANTOM_EXPECT_VERSION="old", PHANTOM_EXPECT_SOURCE_REF="wrong",
                           PHANTOM_EXPECT_METHOD="wrong", PHANTOM_EXPECT_RUNTIME_LITERAL="wrong",
                           PHANTOM_METRIC="wrong", PHANTOM_IMAGE_TAG="wrong")
                if timeout is not None:
                    env["PHANTOM_PROBE_TIMEOUT"] = timeout
                result = subprocess.run([str(wrapper), "0123456789ab" + "c" * 28],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                output = result.stdout.splitlines()
                actual = json.loads(output[1])
                self.assertEqual(actual["PHANTOM_EXPECT_VERSION"], VERSION)
                self.assertEqual(actual["PHANTOM_EXPECT_SOURCE_REF"], SOURCE_REF)
                self.assertEqual(actual["PHANTOM_EXPECT_METHOD"], METHOD)
                self.assertEqual(actual["PHANTOM_EXPECT_RUNTIME_LITERAL"], LITERAL)
                self.assertEqual(actual["PHANTOM_METRIC"], METRIC)
                self.assertEqual(actual["PHANTOM_PROBE_TIMEOUT"], timeout or "0")
                self.assertEqual(output[2], "tag=0123456789ab")


if __name__ == "__main__":
    unittest.main()
