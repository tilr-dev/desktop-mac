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
    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS codesign")
    def test_real_bundle_codesign_with_server_metadata_in_resources(self):
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
            pin = dict(version="0.1.0", build=1, protocolVersion=2)
            (root / "server-release.json").write_text(json.dumps(pin))
            artifact = root / "build/server-releases/0.1.0-1-arm64"
            artifact.mkdir(parents=True)
            binary = artifact / "tilrd"
            shutil.copyfile("/usr/bin/true", binary)
            binary.chmod(0o755)
            subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True, capture_output=True)
            shutil.copyfile(binary, artifact / "tilr")
            (artifact / "tilr").chmod(0o755)
            (artifact / "client.json").write_text(json.dumps(dict(version="0.1.0-test", sha256=bundle_server.digest(binary))))
            meta = self.manifest(1)
            meta["sha256"] = bundle_server.digest(binary)
            (artifact / "app-managed.json").write_text(json.dumps(meta))
            (artifact / "release.json").write_text(json.dumps(dict(preview=False, manifest=meta)))
            with patch.dict(bundle_server.os.environ, {}, clear=True), patch("fetch_server.validate_completed", return_value=meta):
                bundle_server.bundle_server(app, "arm64", 1, root=root)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)

    def manifest(self, build, protocol=2):
        return dict(version="0.1.0", build=build, arch="arm64", serverVersion=f"0.1.0-build{build}-test",
                    sha256="a" * 64, protocolVersion=protocol, minAppBuild=1, maxAppBuild=None)

    def test_app_uses_pinned_artifact_without_building_or_resigning_it(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pin = dict(version="0.1.0", build=1, protocolVersion=2)
            (root / "server-release.json").write_text(json.dumps(pin))
            directory = root / "build/server-releases/0.1.0-1-arm64"
            directory.mkdir(parents=True)
            (directory / "tilrd").write_bytes(b"immutable signed executable")
            (directory / "tilr").write_bytes(b"immutable signed client")
            (directory / "client.json").write_text(json.dumps(dict(version="0.1.0-test", sha256=bundle_server.digest(directory / "tilr"))))
            meta = self.manifest(1)
            meta["sha256"] = bundle_server.digest(directory / "tilrd")
            (directory / "app-managed.json").write_text(json.dumps(meta))
            (directory / "release.json").write_text(json.dumps(dict(preview=False, manifest=meta)))
            calls = []
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == "ditto":
                    shutil.copyfile(command[1], command[2])
            with patch.object(bundle_server.subprocess, "run", side_effect=run), patch.dict(bundle_server.os.environ, {}, clear=True), patch("fetch_server.validate_completed", return_value=meta):
                result = bundle_server.bundle_server(root / "App.app", "arm64", 37, root=root)
            self.assertFalse((root / "App.app/Contents/Helpers/app-managed.json").exists())
            self.assertEqual(json.loads((root / "App.app/Contents/Resources/server/app-managed.json").read_text()), meta)
            self.assertEqual(result["build"], 1)
            self.assertEqual(result["version"], "0.1.0")
            self.assertEqual([c[0] for c in calls], ["ditto", "ditto", "ditto", "ditto", "codesign", "codesign"])
            self.assertNotIn("--sign", calls[-1])
            self.assertEqual((root / "App.app/Contents/Helpers/tilrd").read_bytes(), (directory / "tilrd").read_bytes())
            self.assertEqual((root / "App.app/Contents/Helpers/tilr").read_bytes(), (directory / "tilr").read_bytes())
            self.assertEqual((root / "App.app/Contents/Resources/server/client.json").read_bytes(), (directory / "client.json").read_bytes())

    def test_app_compatibility_and_tampering(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "tilrd").write_bytes(b"server")
            meta = self.manifest(1)
            meta["sha256"] = bundle_server.digest(root / "tilrd")
            meta["minAppBuild"], meta["maxAppBuild"] = 4, 9
            (root / "app-managed.json").write_text(json.dumps(meta))
            bundle_server.validate_payload(root, "arm64", 2, 6)
            for arch, protocol, build in [("x86_64", 2, 6), ("arm64", 3, 6), ("arm64", 2, 10)]:
                with self.assertRaises(ValueError):
                    bundle_server.validate_payload(root, arch, protocol, build)
            (root / "tilrd").write_bytes(b"modified")
            with self.assertRaises(ValueError):
                bundle_server.validate_payload(root, "arm64", 2, 6)


if __name__ == "__main__":
    unittest.main()
