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
            binary = artifact / "tilr-server"
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
            (directory / "tilr-server").write_bytes(b"immutable signed executable")
            meta = self.manifest(1)
            meta["sha256"] = bundle_server.digest(directory / "tilr-server")
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
            self.assertEqual((root / "App.app/Contents/Helpers/tilr-server").read_bytes(), (directory / "tilr-server").read_bytes())

    def test_app_compatibility_and_tampering(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "tilr-server").write_bytes(b"server")
            meta = self.manifest(1)
            meta["sha256"] = bundle_server.digest(root / "tilr-server")
            meta["minAppBuild"], meta["maxAppBuild"] = 4, 9
            (root / "app-managed.json").write_text(json.dumps(meta))
            bundle_server.validate_payload(root, "arm64", 2, 6)
            for arch, protocol, build in [("x86_64", 2, 6), ("arm64", 3, 6), ("arm64", 2, 10)]:
                with self.assertRaises(ValueError):
                    bundle_server.validate_payload(root, arch, protocol, build)
            (root / "tilr-server").write_bytes(b"modified")
            with self.assertRaises(ValueError):
                bundle_server.validate_payload(root, "arm64", 2, 6)

    def publication(self, corrupt=False):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            binary = directory / "tilr-server"
            binary.write_bytes(b"server")
            manifest = self.manifest(1)
            manifest["sha256"] = bundle_server.digest(binary)
            objects, uploads = {}, []
            def fetch(url, target):
                if url not in objects:
                    return False
                target.write_bytes(objects[url])
                return True
            def run(*args, **kwargs):
                if args[0] == "wrangler":
                    url = release_server.CDN + "/" + args[4].split("/", 1)[1]
                    data = Path(args[args.index("--file") + 1]).read_bytes()
                    uploads.append(url)
                    objects[url] = b"corrupt" if corrupt and url.endswith("tilr-server") else data
            with patch.object(release_server, "fetch", side_effect=fetch), \
                 patch.object(release_server, "run", side_effect=run), \
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
        self.assertTrue(urls[0].endswith("/tilr-server"))
        self.assertTrue(urls[1].endswith("/server/macos/arm64/stable.json"))
        self.assertFalse(any("appcast" in url or ".dmg" in url for url in urls))

    def test_bad_public_download_leaves_the_server_feed_unchanged(self):
        urls = self.publication(corrupt=True)
        self.assertEqual(len(urls), 1)
        self.assertTrue(urls[0].endswith("/tilr-server"))


if __name__ == "__main__":
    unittest.main()
