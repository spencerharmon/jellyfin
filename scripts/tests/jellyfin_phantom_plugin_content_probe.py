"""Registry artifact checks shared by the metric and zero-seed shell probes."""

import hashlib
import io
import json
from pathlib import PurePosixPath
import re
import sys
import tarfile
import urllib.error
import urllib.request


ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def probe(cfg):
    base = "https://%s/v2/%s" % (cfg["host"], cfg["repo"])

    def fetch(path, expected=None, manifest=False):
        req = urllib.request.Request(base + path)
        req.add_header("Authorization", "Bearer " + cfg["token"])
        if manifest:
            req.add_header("Accept", ACCEPT)
        with urllib.request.urlopen(req, timeout=120) as response:
            data = response.read()
            advertised = response.headers.get("Docker-Content-Digest")
        actual = "sha256:" + hashlib.sha256(data).hexdigest()
        if expected is None and not advertised:
            raise ValueError("registry omitted top-level Docker-Content-Digest")
        for digest in (expected, advertised):
            if digest is not None and digest != actual:
                raise ValueError("digest mismatch for %s: expected %s, got %s"
                                 % (path, digest, actual))
        return (json.loads(data) if manifest else data), actual

    try:
        man, top_digest = fetch("/manifests/" + cfg["tag"], manifest=True)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            print("manifest not yet available for tag", cfg["tag"], file=sys.stderr)
            return 3
        raise
    print("manifest_digest=" + top_digest, flush=True)

    if "manifests" in man and "layers" not in man:
        chosen = next((m for m in man["manifests"]
                       if m.get("platform", {}).get("os") == "linux"
                       and m.get("platform", {}).get("architecture") == "amd64"), None)
        if chosen is None:
            raise ValueError("manifest index has no linux/amd64 image")
        man, child_digest = fetch("/manifests/" + chosen["digest"],
                                  chosen["digest"], manifest=True)
        print("platform=linux/amd64 child_manifest_digest=" + child_digest, flush=True)

    layers = man.get("layers", [])
    if not layers:
        raise ValueError("manifest has no layers")
    target = PurePosixPath(cfg["dll_suffix"])
    ancestors = list(target.parents)
    # OCI whiteouts mask lower layers, including deletions/opacity of any parent.
    whiteouts = {str(p.parent / (".wh." + p.name)) for p in [target] + ancestors if p.name}
    whiteouts.update(str(p / ".wh..wh..opq") for p in ancestors)
    for layer in reversed(layers):
        blob, digest = fetch("/blobs/" + layer["digest"], layer["digest"])
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as archive:
            members = {str(PurePosixPath(m.name)): m for m in archive.getmembers()}
            for parent in ancestors:
                member = members.get(str(parent))
                if member is not None and not member.isdir():
                    raise ValueError("plugin ancestor replaced by non-directory: " + str(parent))
            member = members.get(str(target))
            if member is None:
                if whiteouts.intersection(members):
                    raise ValueError("plugin DLL deleted or hidden by whiteout in " + digest)
                continue
            # Never follow links into another member or fall back to an older DLL.
            if not member.isfile():
                raise ValueError("plugin DLL is not a regular file")
            with archive.extractfile(member) as stream:
                dll = stream.read()
        print("plugin_dll_sha256=" + hashlib.sha256(dll).hexdigest(), flush=True)
        expectations = {key: cfg[key] for key in
                        ("metric", "version", "source_ref", "method", "runtime_literal")
                        if cfg.get(key)}
        print("expectations=" + json.dumps(expectations, sort_keys=True), flush=True)
        # Metadata/custom-attribute strings are UTF-8; .NET #US literals are UTF-16LE.
        metric = cfg["metric"]
        if not any(metric.encode(enc) in dll for enc in ("utf-8", "utf-16-le")):
            raise ValueError("DLL does NOT contain metric " + metric)
        for key in ("version", "source_ref"):
            if cfg.get(key):
                value = cfg[key].encode("ascii")
                # A custom-attribute SerString has a length prefix, not a NUL prefix.
                # For version+full-SHA this is 48 (ASCII '0'), defeating a word boundary.
                if key == "version" and len(value) + 41 < 128:
                    serialized = re.escape(bytes([len(value) + 41]) + value + b"+")
                    if re.search(serialized + rb"[0-9a-f]{40}", dll):
                        continue
                boundary = rb"[0-9A-Za-z_.]" if key == "version" else rb"[0-9a-fA-F]"
                pattern = rb"(?<!" + boundary + rb")" + re.escape(value)
                if not re.search(pattern + rb"(?!" + boundary + rb")", dll):
                    raise ValueError("DLL does NOT contain expected " + key + " " + cfg[key])
        for key, encoding in (("method", "ascii"), ("runtime_literal", "utf-16-le")):
            if cfg.get(key) and cfg[key].encode(encoding) not in dll:
                raise ValueError("DLL does NOT contain expected " + key + " " + cfg[key])
        print("OK: %s (%d bytes) in layer %s meets all expectations"
              % (target, len(dll), digest))
        return 0
    raise ValueError("plugin DLL not found in image " + cfg["tag"])


def main():
    try:
        return probe(json.load(sys.stdin))
    except (ValueError, KeyError, TypeError, OSError, tarfile.TarError,
            urllib.error.URLError) as exc:
        print("FAIL: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
