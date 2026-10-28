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
        self.args = argparse.Namespace(version="0.1.0", build=7, protocol_version=1, preview=False)
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "release_server.py").write_text('''import json,os,pathlib,sys
args = sys.argv[1:]
def value(flag): return args[args.index(flag)+1]
assert value("--protocol-version") == "1"
assert args == ["--version", "0.1.0", "--build", "7", "--protocol-version", "1"]
assert "--source" not in args
step = "acquire"
with open(os.environ["EVENTS"], "a") as f: f.write(step+"\\n")
if os.environ.get("FAIL_STEP") == step: sys.exit(1)
for arch in ("arm64", "x86_64"):
    path = pathlib.Path(__file__).parents[1] / "build/server-releases" / f"0.1.0-7-{arch}"
    path.mkdir(parents=True, exist_ok=True)
    manifest = dict(version="0.1.0", build=7, arch=arch, protocolVersion=1, minAppBuild=2, serverVersion="0.1.0-abc123")
    (path / "release.json").write_text(json.dumps(dict(preview=False, manifest=manifest)))
''')
        self.events = self.root / "events"
        self.env = dict(os.environ, EVENTS=str(self.events))

    def execute(self, fail=None, invalid_arch=None, output=None):
        output = output if output is not None else io.StringIO()
        if fail:
            self.env["FAIL_STEP"] = fail
        def validate(directory, version, build, arch, protocol):
            self.assertEqual((version, build, protocol), ("0.1.0", 7, 1))
            if arch == invalid_arch:
                raise ValueError("Invalid upstream artifact")
            manifest = json.loads((directory / "release.json").read_text())["manifest"]
            self.assertEqual(manifest["arch"], arch)
            return manifest
        with patch.object(release, "release_environment", return_value=self.env) as environment, \
             patch("builtins.input", side_effect=AssertionError("Unexpected publication prompt")), \
             patch.object(release, "validate_completed", side_effect=validate) as validation, \
             redirect_stdout(output):
            release.execute(self.args, self.root)
            if self.args.preview:
                environment.assert_not_called()
                validation.assert_not_called()
            else:
                self.assertEqual(validation.call_count, 2)
        return output.getvalue()

    def test_import_validates_both_artifacts_and_prints_pin_without_publication(self):
        output = self.execute()
        self.assertEqual(self.events.read_text().splitlines(), ["acquire"])
        self.assertIn('server-release.json: {"version": "0.1.0", "build": 7, "protocolVersion": 1}', output)
        self.assertEqual(output.count('"serverVersion": "0.1.0-abc123"'), 2)

    def test_preview_without_credentials_or_checkout(self):
        self.args.preview = True
        with patch.dict(os.environ, {}, clear=True):
            output = self.execute()
        self.assertIn("Planned:", output)
        self.assertIn('--protocol-version 1', output)
        self.assertNotIn('--source', output)
        self.assertIn('"protocolVersion": 1', output)
        self.assertFalse(self.events.exists())

    def test_acquisition_failure_stops_before_validation(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute(fail="acquire")
        self.assertEqual(self.events.read_text().splitlines(), ["acquire"])

    def test_invalid_artifact_does_not_print_successful_pin(self):
        for arch in release.TARGETS:
            output = io.StringIO()
            with redirect_stdout(output), self.assertRaisesRegex(ValueError, "Invalid upstream"):
                self.execute(invalid_arch=arch, output=output)
            self.assertNotIn("server-release.json:", output.getvalue())

    def test_invalid_protocol_stops_before_acquisition(self):
        for protocol in (0, -1, 4294967296):
            self.args.protocol_version = protocol
            with self.assertRaisesRegex(ValueError, "positive u32"):
                self.execute()
        self.assertFalse(self.events.exists())

    def test_homebrew_tools_come_first(self):
        self.assertTrue(release.release_environment()["PATH"].startswith("/opt/homebrew/bin:"))

    def test_obsolete_feed_options_are_rejected(self):
        for option in (["--publish"], ["--publish-only"], ["--channel", "beta"],
                       ["--min-app-build", "2"], ["--max-app-build", "9"]):
            command = [sys.executable, str(Path(release.__file__)), "--version", "0.1.0",
                       "--build", "7", "--protocol-version", "1", *option]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("unrecognized arguments", result.stderr)


if __name__ == "__main__":
    unittest.main()
