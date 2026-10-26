import argparse
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import release_server_all as release


class ServerReleaseCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.args = argparse.Namespace(version="0.1.0", build=7, min_app_build=2,
                                       protocol_version=1, channel="beta", preview=False)
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "release_all.py").write_text('''import os,sys
assert sys.argv[1:] == ["--check", "--publish-only"]
with open(os.environ["EVENTS"], "a") as f: f.write("preflight\\n")
if os.environ.get("FAIL_STEP") == "preflight": sys.exit(1)
''')
        (scripts / "release_server.py").write_text('''import json,os,pathlib,sys
args = sys.argv[1:]
def value(flag): return args[args.index(flag)+1]
assert value("--protocol-version") == "1"
assert value("--min-app-build") == "2"
assert "--source" not in args
step = "publish" if "--publish-only" in args else "acquire"
with open(os.environ["EVENTS"], "a") as f: f.write(step+"\\n")
if os.environ.get("FAIL_STEP") == step: sys.exit(1)
if step == "publish": sys.exit(0)
for arch in ("arm64", "x86_64"):
    path = pathlib.Path(__file__).parents[1] / "build/server-releases" / f"0.1.0-7-{arch}"
    path.mkdir(parents=True, exist_ok=True)
    manifest = dict(version="0.1.0", build=7, arch=arch, protocolVersion=1, minAppBuild=2, serverVersion="0.1.0-abc123")
    (path / "release.json").write_text(json.dumps(dict(preview=False, manifest=manifest)))
''')
        self.events = self.root / "events"
        self.env = dict(os.environ, EVENTS=str(self.events))

    def execute(self, answer="publish", fail=None):
        output = io.StringIO()
        if fail:
            self.env["FAIL_STEP"] = fail
        def feed_fetch(url, path):
            arch = "arm64" if "/arm64/" in url else "x86_64"
            manifest = json.loads((self.root / f"build/server-releases/0.1.0-7-{arch}/release.json").read_text())["manifest"]
            path.write_text(json.dumps(dict(schema=1, component="tilrd", arch=arch, channel="beta", releases=[dict(manifest=manifest)])))
            with self.events.open("a") as file:
                file.write("feed-" + arch + "\n")
            return True
        def validate(directory, version, build, arch, protocol):
            self.assertEqual((version, build, protocol), ("0.1.0", 7, 1))
            manifest = json.loads((directory / "release.json").read_text())["manifest"]
            self.assertEqual(manifest["arch"], arch)
            return manifest
        with patch.object(release, "release_environment", return_value=self.env) as environment, \
             patch("builtins.input", side_effect=EOFError if answer is None else None, return_value=answer), \
             patch.object(release, "fetch", side_effect=feed_fetch), \
             patch.object(release, "validate_completed", side_effect=validate) as validation, \
             patch.object(release, "verify_envelope", side_effect=lambda data, _: json.loads(data)), \
             redirect_stdout(output):
            release.execute(self.args, self.root)
            if self.args.preview:
                environment.assert_not_called()
                validation.assert_not_called()
            else:
                self.assertEqual(validation.call_count, 2)
        return output.getvalue()

    def test_import_orders_validation_confirmation_feeds_and_pin(self):
        output = self.execute()
        self.assertEqual(self.events.read_text().splitlines(), ["preflight", "acquire", "publish", "feed-arm64", "feed-x86_64"])
        self.assertIn('server-release.json: {"version": "0.1.0", "build": 7, "protocolVersion": 1}', output)
        self.assertIn('"serverVersion": "0.1.0-abc123"', output)

    def test_refusal_and_eof_leave_imported_artifacts_unpublished(self):
        for answer in ("yes", "", None):
            with self.subTest(answer=answer):
                self.events.write_text("")
                self.execute(answer)
                self.assertNotIn("publish", self.events.read_text())
                self.assertTrue((self.root / "build/server-releases/0.1.0-7-arm64/release.json").exists())

    def test_preview_without_credentials_or_checkout(self):
        self.args.preview = True
        with patch.dict(os.environ, {}, clear=True):
            output = self.execute()
        self.assertIn("Planned:", output)
        self.assertIn('--protocol-version 1', output)
        self.assertNotIn('--source', output)
        self.assertIn('"protocolVersion": 1', output)
        self.assertFalse(self.events.exists())

    def test_failure_stops_later_steps(self):
        for step in ("preflight", "acquire", "publish"):
            with self.subTest(step=step):
                self.events.write_text("")
                with self.assertRaises(subprocess.CalledProcessError):
                    self.execute(fail=step)
                events = self.events.read_text().splitlines()
                self.assertNotIn("feed-arm64", events)
                if step == "preflight":
                    self.assertNotIn("acquire", events)

    def test_invalid_protocol_stops_before_preflight(self):
        for protocol in (0, -1, 4294967296):
            self.args.protocol_version = protocol
            with self.assertRaisesRegex(ValueError, "positive u32"):
                self.execute()
        self.assertFalse(self.events.exists())

    def test_homebrew_tools_come_first(self):
        self.assertTrue(release.release_environment()["PATH"].startswith("/opt/homebrew/bin:"))

    def test_wrong_feed_fails(self):
        directory = self.root / "artifact"
        directory.mkdir()
        def fetch(_, path):
            path.write_text("{}")
            return True
        with patch.object(release, "fetch", side_effect=fetch), \
             patch.object(release, "verify_envelope", return_value=dict(arch="arm64", releases=[])):
            with self.assertRaisesRegex(ValueError, "does not contain"):
                release.verify_feeds([("arm64", directory, {"build": 7})], "stable")


if __name__ == "__main__":
    unittest.main()
