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
import release_server


class IndependentServerReleaseTests(unittest.TestCase):
    def test_builds_tilrd_package_and_packages_its_signed_binary(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            core = root / "tilrd-source"
            proto = core / "crates/tilr-proto/src/lib.rs"
            proto.parent.mkdir(parents=True)
            proto.write_text("pub const PROTOCOL_VERSION: u32 = 1;")
            output = core / "target/aarch64-apple-darwin/release/tilrd"
            calls = []
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == "cargo":
                    self.assertEqual(command[command.index("-p") + 1], "tilrd")
                    self.assertEqual(kwargs["cwd"], core)
                    self.assertEqual(kwargs["env"]["TILR_BUILD_VERSION"], "0.2.0-build7")
                    output.parent.mkdir(parents=True)
                    output.write_bytes(b"built tilrd executable")
                elif command[0] == "ditto":
                    self.assertEqual(Path(command[1]), output)
                    shutil.copyfile(command[1], command[2])
            destination = root / "artifact"
            def sign(binary):
                binary.write_bytes(binary.read_bytes() + b" signed")
            with patch.object(bundle_server.subprocess, "check_output", return_value="abc123\n"), \
                 patch.object(bundle_server.subprocess, "run", side_effect=run), \
                 patch.object(bundle_server, "strip_executable"):
                meta = bundle_server.build_server(destination, "arm64", "0.2.0", 7, sign, core=core)
            self.assertEqual((destination / "tilrd").read_bytes(), b"built tilrd executable signed")
            self.assertEqual(meta["protocolVersion"], 1)
            self.assertEqual(meta["sha256"], bundle_server.digest(destination / "tilrd"))
            self.assertEqual(json.loads((destination / "app-managed.json").read_text()), meta)

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
            meta = self.manifest(1)
            meta["sha256"] = bundle_server.digest(binary)
            (artifact / "app-managed.json").write_text(json.dumps(meta))
            (artifact / "release.json").write_text(json.dumps(dict(preview=False, manifest=meta)))
            with patch.dict(bundle_server.os.environ, {}, clear=True):
                bundle_server.bundle_server(app, "arm64", 1, root=root)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)

    def manifest(self, build, protocol=2):
        return dict(version="0.1.0", build=build, arch="arm64", serverVersion=f"0.1.0-build{build}-test",
                    sha256="a" * 64, protocolVersion=protocol, minAppBuild=1, maxAppBuild=None)

    def test_tracks_keep_older_protocols_and_ignore_app_build_numbers(self):
        first = release_server.next_feed(None, self.manifest(1), 100, "stable")
        self.assertEqual(first["component"], "tilrd")
        latest = release_server.next_feed(first, self.manifest(2, protocol=3), 100, "stable")
        self.assertEqual([r["manifest"]["protocolVersion"] for r in latest["releases"]], [3, 2])
        self.assertEqual(release_server.next_feed(latest, self.manifest(2, protocol=3), 100, "stable"), latest)
        self.assertNotIn("/mac/arm64/appcast", latest["releases"][0]["url"])
        with self.assertRaises(ValueError):
            release_server.next_feed(latest, self.manifest(2), 100, "stable")
        with self.assertRaises(ValueError):
            release_server.next_feed(latest, self.manifest(3), 100, "beta")

    def test_app_uses_pinned_artifact_without_building_or_resigning_it(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pin = dict(version="0.1.0", build=1, protocolVersion=2)
            (root / "server-release.json").write_text(json.dumps(pin))
            directory = root / "build/server-releases/0.1.0-1-arm64"
            directory.mkdir(parents=True)
            (directory / "tilrd").write_bytes(b"immutable signed executable")
            meta = self.manifest(1)
            meta["sha256"] = bundle_server.digest(directory / "tilrd")
            (directory / "app-managed.json").write_text(json.dumps(meta))
            (directory / "release.json").write_text(json.dumps(dict(preview=False, manifest=meta)))
            calls = []
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == "ditto":
                    shutil.copyfile(command[1], command[2])
            with patch.object(bundle_server.subprocess, "run", side_effect=run), patch.dict(bundle_server.os.environ, {}, clear=True):
                result = bundle_server.bundle_server(root / "App.app", "arm64", 37, root=root)
            self.assertFalse((root / "App.app/Contents/Helpers/app-managed.json").exists())
            self.assertEqual(json.loads((root / "App.app/Contents/Resources/server/app-managed.json").read_text()), meta)
            self.assertEqual(result["build"], 1)
            self.assertEqual(result["version"], "0.1.0")
            self.assertEqual([c[0] for c in calls], ["ditto", "ditto", "codesign"])
            self.assertNotIn("--sign", calls[-1])
            self.assertEqual((root / "App.app/Contents/Helpers/tilrd").read_bytes(), (directory / "tilrd").read_bytes())

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

    def publication(self, corrupt=False):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            binary = directory / "tilrd"
            binary.write_bytes(b"server")
            manifest = self.manifest(1)
            manifest["sha256"] = bundle_server.digest(binary)
            objects, uploads = {}, []
            def fetch(url, target):
                if url not in objects:
                    return False
                target.write_bytes(objects[url])
                return True
            def put(path, key, content_type, cache):
                url = release_server.CDN + "/" + key
                uploads.append(url)
                objects[url] = b"corrupt" if corrupt and url.endswith("tilrd") else Path(path).read_bytes()
            with patch.object(release_server, "fetch", side_effect=fetch), \
                 patch.object(release_server, "put_object", side_effect=put), \
                 patch.object(release_server, "signed_feed", side_effect=lambda feed, _: release_server.canonical(feed)), \
                 patch.object(release_server, "verify_envelope", side_effect=lambda data, _: json.loads(data)):
                if corrupt:
                    with self.assertRaisesRegex(ValueError, "not verified"):
                        release_server.publish_release(directory, manifest, "stable")
                else:
                    release_server.publish_release(directory, manifest, "stable")
            return uploads

    def test_server_binary_verified_before_feed_and_app_feed_never_touched(self):
        urls = self.publication()
        self.assertEqual(len(urls), 2)
        self.assertTrue(urls[0].endswith("/tilrd"))
        self.assertTrue(urls[1].endswith("/server/macos/arm64/stable.json"))
        self.assertFalse(any("appcast" in url or ".dmg" in url for url in urls))

    def test_bad_public_download_leaves_the_server_feed_unchanged(self):
        urls = self.publication(corrupt=True)
        self.assertEqual(len(urls), 1)
        self.assertTrue(urls[0].endswith("/tilrd"))


if __name__ == "__main__":
    unittest.main()
