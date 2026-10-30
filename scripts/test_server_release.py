import json
from pathlib import Path
import shutil
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import bundle_server


class IndependentServerReleaseTests(unittest.TestCase):
    def artifact(self, root, protocol=2, server=b"immutable signed executable", client=b"immutable signed client"):
        """A completed acquisition of the latest stable release, as fetch_server.py leaves it."""
        releases = root / "build/server-releases"
        directory = releases / "0.1.0-arm64"
        directory.mkdir(parents=True)
        (directory / "tilrd").write_bytes(server)
        (directory / "tilr").write_bytes(client)
        for name in ("tilrd", "tilr"):
            (directory / name).chmod(0o755)
        meta = dict(version="0.1.0", arch="arm64", serverVersion="0.1.0-test",
                    sha256=bundle_server.digest(directory / "tilrd"), protocolVersion=protocol)
        (directory / "server.json").write_text(json.dumps(meta))
        (directory / "release.json").write_text(json.dumps(dict(preview=False, manifest=meta)))
        (releases / "selected.json").write_text(json.dumps(dict(version="0.1.0", protocolVersion=protocol)))
        return directory, meta

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS codesign")
    def test_real_bundle_codesign_with_bundled_server_helpers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = root / "Tilr.app"
            executable = app / "Contents/MacOS/Tilr"
            executable.parent.mkdir(parents=True)
            shutil.copyfile("/usr/bin/true", executable)
            executable.chmod(0o755)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
                CFBundleExecutable="Tilr", CFBundleIdentifier="dev.tilr.signing-test",
                CFBundlePackageType="APPL", CFBundleVersion="1")))
            signed = root / "signed"
            shutil.copyfile("/usr/bin/true", signed)
            signed.chmod(0o755)
            subprocess.run(["codesign", "--force", "--sign", "-", str(signed)], check=True, capture_output=True)
            _, meta = self.artifact(root, server=signed.read_bytes(), client=signed.read_bytes())
            with patch.dict(bundle_server.os.environ, {}, clear=True), patch("fetch_server.validate_completed", return_value=meta):
                bundle_server.bundle_server(app, "arm64", 2, root=root)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)

    def test_app_uses_selected_artifact_without_building_resigning_or_pin_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            directory, meta = self.artifact(root)
            calls = []
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == "ditto":
                    shutil.copyfile(command[1], command[2])
            with patch.object(bundle_server.subprocess, "run", side_effect=run), patch.dict(bundle_server.os.environ, {}, clear=True), \
                    patch("fetch_server.validate_completed", return_value=meta) as validate:
                result = bundle_server.bundle_server(root / "App.app", "arm64", 2, root=root)
            validate.assert_called_once_with(directory, "0.1.0", "arm64", 2)
            self.assertEqual(result, meta)
            self.assertFalse((root / "App.app/Contents/Resources/server").exists())
            self.assertEqual([c[0] for c in calls], ["ditto", "ditto", "codesign", "codesign"])
            self.assertNotIn("--sign", calls[-1])
            self.assertEqual((root / "App.app/Contents/Helpers/tilrd").read_bytes(), (directory / "tilrd").read_bytes())
            self.assertEqual((root / "App.app/Contents/Helpers/tilr").read_bytes(), (directory / "tilr").read_bytes())

    def test_protocol_mismatch_or_missing_acquisition_stops_bundling(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.dict(bundle_server.os.environ, {}, clear=True):
                with self.assertRaisesRegex(ValueError, "Acquire the latest upstream server release first"):
                    bundle_server.bundle_server(root / "App.app", "arm64", 2, root=root)
                self.artifact(root, protocol=2)
                with self.assertRaisesRegex(ValueError, "protocol does not match"):
                    bundle_server.bundle_server(root / "App.app", "arm64", 1, root=root)
                with self.assertRaises(ValueError):
                    bundle_server.bundle_server(root / "App.app", "universal", 2, root=root)
            self.assertFalse((root / "App.app").exists())

    def test_packaged_app_with_pin_metadata_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "App.app"
            (app / "Contents/Resources/server").mkdir(parents=True)
            for info in (dict(TilrServerProtocolVersion=1, TilrBundledServerVersion="0.1.0"), dict(TilrServerProtocolVersion=1), dict()):
                with self.subTest(info=info):
                    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                    with self.assertRaises(ValueError):
                        bundle_server.verify_server(app, "arm64")


if __name__ == "__main__":
    unittest.main()
