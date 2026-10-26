import base64
import hashlib
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import fetch_server


class FetchPublishedServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "server-release.json").write_text(json.dumps({"version": "0.2.0", "build": 3, "protocolVersion": 1}))
        self.binary = b"signed tilrd"
        self.remote = {}

    def publish(self, arch, build=3, binary=None):
        manifest = dict(version="0.2.0", build=build, arch=arch, sha256=hashlib.sha256(self.binary).hexdigest(),
                        protocolVersion=1, minAppBuild=10, maxAppBuild=None, serverVersion="0.2.0-build3-abc")
        payload = dict(schema=1, component="tilrd", arch=arch, channel="stable",
                       releases=[dict(manifest=manifest, size=len(self.binary), url=fetch_server.release_url(manifest))])
        envelope = dict(payload=base64.b64encode(json.dumps(payload).encode()).decode(), signature="sig")
        self.remote[fetch_server.feed_url(arch, "stable")] = json.dumps(envelope).encode()
        self.remote[fetch_server.release_url(manifest)] = self.binary if binary is None else binary
        return manifest

    def fetch(self, url, path):
        if url not in self.remote:
            return False
        path.write_bytes(self.remote[url])
        return True

    def main(self):
        with patch.object(fetch_server, "ROOT", self.root), patch.object(fetch_server, "fetch", self.fetch), \
             patch.object(fetch_server, "check_signature") as signature, \
             patch("sys.argv", ["fetch_server.py", "--public-key", "public"]), redirect_stdout(io.StringIO()):
            result = fetch_server.main()
        return result, signature

    def test_unpublished_pin_asks_for_a_build(self):
        result, _ = self.main()
        self.assertEqual(result, fetch_server.NOT_PUBLISHED)
        self.assertFalse((self.root / "build").exists())

    def test_published_pin_is_reused_as_a_completed_release(self):
        manifests = {arch: self.publish(arch) for arch in ("arm64", "x86_64")}
        result, signature = self.main()
        self.assertEqual(result, 0)
        self.assertEqual(signature.call_count, 2)
        for arch, manifest in manifests.items():
            directory = self.root / "build/server-releases" / f"0.2.0-3-{arch}"
            self.assertEqual((directory / "tilrd").read_bytes(), self.binary)
            self.assertEqual(json.loads((directory / "app-managed.json").read_text()), manifest)
            receipt = json.loads((directory / "release.json").read_text())
            self.assertEqual((receipt["preview"], receipt["manifest"], receipt["public_key"]), (False, manifest, "public"))

    def test_other_published_builds_do_not_count(self):
        for arch in ("arm64", "x86_64"):
            self.publish(arch, build=2)
        self.assertEqual(self.main()[0], fetch_server.NOT_PUBLISHED)

    def test_partial_publication_stops(self):
        self.publish("arm64")
        with self.assertRaisesRegex(ValueError, "some architectures only"):
            self.main()

    def test_checksum_mismatch_stops_without_output(self):
        self.publish("arm64")
        self.publish("x86_64", binary=b"other bytes")
        with self.assertRaisesRegex(ValueError, "differs from its feed checksum"):
            self.main()
        self.assertFalse((self.root / "build").exists())


if __name__ == "__main__":
    unittest.main()
