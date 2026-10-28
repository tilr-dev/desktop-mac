"""Release safety checks; no Apple credentials, disk images or network needed."""
import base64
import json
from pathlib import Path
import plistlib
import tempfile
import sys
import unittest
from unittest.mock import patch
import publish


def feed(build=2, size=3, url="https://cdn.tilr.dev/mac/arm64/Tilr-0.1.1-2-arm64.dmg"):
    sig = base64.b64encode(bytes(64)).decode()
    return f'''<rss xmlns:sparkle="{publish.SPARKLE}"><channel><item>
    <sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>
    <enclosure url="{url}" length="{size}" sparkle:edSignature="{sig}" />
    </item></channel></rss>'''.encode()


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dmg = self.root / "Tilr-0.1.1-2-arm64.dmg"
        self.dmg.write_bytes(b"dmg")
        self.meta = dict(version="0.1.1", build=2, arch="arm64", preview=False,
                         dmg=self.dmg.name, sha256=publish.digest(self.dmg),
                         feed="https://cdn.tilr.dev/mac/arm64/appcast.xml", public_key="public")
        info = self.root / "Tilr.app/Contents/Info.plist"
        info.parent.mkdir(parents=True)
        with info.open("wb") as file:
            plistlib.dump(dict(CFBundleIdentifier="dev.tilr.mac", CFBundleVersion="2",
                               CFBundleShortVersionString="0.1.1", SUFeedURL=self.meta["feed"],
                               SUPublicEDKey="public", TilrServerProtocolVersion=1, TilrBundledServerBuild=2,
                               TilrBundledServerVersion="0.1.1"), file)
        helpers = self.root / "Tilr.app/Contents/Helpers"
        helpers.mkdir()
        (helpers / "tilrd").write_bytes(b"server")
        (helpers / "tilr").write_bytes(b"client")
        resources = self.root / "Tilr.app/Contents/Resources/server"
        resources.mkdir(parents=True)
        (resources / "app-managed.json").write_text(json.dumps(dict(
            version="0.1.1", build=2, arch="arm64", serverVersion="0.1.1-build2-test",
            sha256=publish.digest(helpers / "tilrd"), protocolVersion=1, minAppBuild=1, maxAppBuild=None)))
        (resources / "client.json").write_text(json.dumps(dict(
            version="0.1.1-build2-test", sha256=publish.digest(helpers / "tilr"))))
        # These publication fixtures use bytes, not signed Mach-O executables.
        binary_check = patch("fetch_server.check_binary", return_value="0.1.1-build2-test")
        binary_check.start()
        self.addCleanup(binary_check.stop)
        self.manifest()

    def test_protocol_one_release_rejects_other_server_protocols(self):
        publish.validate_manifest(self.root)
        path = self.root / "Tilr.app/Contents/Resources/server/app-managed.json"
        manifest = json.loads(path.read_text())
        for protocol in (0, 2):
            with self.subTest(protocol=protocol):
                manifest["protocolVersion"] = protocol
                path.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, "protocol does not match"):
                    publish.validate_manifest(self.root)

    def test_server_missing_tampered_or_wrong_build_blocks_publication(self):
        helpers = self.root / "Tilr.app/Contents/Helpers"
        (helpers / "tilrd").write_bytes(b"different")
        with self.assertRaisesRegex(ValueError, "server checksum"):
            publish.validate_manifest(self.root)
        (helpers / "tilrd").write_bytes(b"server")
        path = self.root / "Tilr.app/Contents/Resources/server/app-managed.json"
        meta = json.loads(path.read_text())
        meta["build"] = 1
        path.write_text(json.dumps(meta))
        with self.assertRaisesRegex(ValueError, "server differs"):
            publish.validate_manifest(self.root)
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            publish.validate_manifest(self.root)

    def manifest(self):
        (self.root / "release.json").write_text(json.dumps(self.meta))

    def test_preview_tampering_and_wrong_destination_rejected(self):
        publish.validate_manifest(self.root)
        for change in ({"preview": True}, {"feed": "https://other.example/appcast.xml"},
                       {"sha256": "0" * 64}, {"dmg": "../escape.dmg"}, {"build": 3}):
            original = self.meta.copy()
            self.meta.update(change)
            self.manifest()
            with self.assertRaises(ValueError):
                publish.validate_manifest(self.root)
            self.meta = original
        self.manifest()

    def test_runtime_feed_metadata_and_legacy_validation(self):
        path = self.root / "Tilr.app/Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        # Completed channel-bound legacy artifacts still validate unchanged.
        publish.validate_manifest(self.root)
        info.pop("SUFeedURL")
        info["TilrUpdateFeedSelection"] = "preferences"
        path.write_bytes(plistlib.dumps(info))
        for channel in ("stable", "beta"):
            self.meta["feed"] = f"https://cdn.tilr.dev/mac/{'beta/' if channel == 'beta' else ''}arm64/appcast.xml"
            self.manifest()
            publish.validate_manifest(self.root)
        for change in ({"TilrUpdateFeedSelection": "unknown"},
                       {"SUFeedURL": self.meta["feed"]}, {"SUPublicEDKey": "wrong"}):
            with self.subTest(change=change):
                path.write_bytes(plistlib.dumps({**info, **change}))
                with self.assertRaises(ValueError):
                    publish.validate_manifest(self.root)
        del info["TilrUpdateFeedSelection"]
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError):
            publish.validate_manifest(self.root)

    def test_downgrade_or_duplicate_rejected(self):
        publish.check_newer(None, 2)
        publish.check_newer(feed(1), 2)
        for previous in (2, 3):
            with self.assertRaises(ValueError):
                publish.check_newer(feed(previous), 2)

    def test_feed_must_match_archive(self):
        publish.validate_candidate(feed(), self.meta, self.dmg)
        for data in (feed(size=4), feed(build=1), feed(url="https://other.example/file.dmg"),
                     feed().replace(b"edSignature=", b"missingSignature=")):
            with self.assertRaises(ValueError):
                publish.validate_candidate(data, self.meta, self.dmg)

    def test_new_feeds_disallow_skipping_for_all_versions(self):
        with self.assertRaisesRegex(ValueError, "disable version skipping"):
            publish.validate_candidate(feed(), self.meta, self.dmg, require_no_skip=True)
        critical = feed().replace(b"<item>", b"<item><sparkle:criticalUpdate />")
        publish.validate_candidate(critical, self.meta, self.dmg, require_no_skip=True)
        limited = critical.replace(b"criticalUpdate /", b'criticalUpdate sparkle:version="1" /')
        with self.assertRaisesRegex(ValueError, "disable version skipping"):
            publish.validate_candidate(limited, self.meta, self.dmg, require_no_skip=True)

    def test_network_failure_is_not_first_release(self):
        for status in ("403", "500", "000"):
            with patch.object(publish, "run") as run:
                run.return_value.stdout = status
                with self.assertRaises(ValueError):
                    publish.fetch(self.meta["feed"], self.root / "remote.xml")

    def test_feed_is_uploaded_last_after_dmg_download_verification(self):
        candidate = self.root / "appcast.xml"
        candidate.write_bytes(feed())
        events = []
        count = 0

        def fetch(url, target):
            nonlocal count
            events.append(("get", url))
            if publish.urlsplit(url).path.endswith(".dmg"):
                count += 1
                if count == 1:
                    return False
                target.write_bytes(b"dmg")
            elif any(event == ("put", "mac/arm64/appcast.xml") for event in events):
                target.write_bytes(candidate.read_bytes())
            else:
                return False
            return True

        with patch.object(publish, "fetch", side_effect=fetch), patch.object(publish, "put", side_effect=lambda p, key, *a: events.append(("put", key))):
            publish.upload_verified_assets(self.meta, self.dmg, candidate, self.root)
        puts = [key for event, key in events if event == "put"]
        self.assertEqual(puts, ["mac/arm64/" + self.dmg.name, "mac/arm64/" + self.dmg.name + ".sha256", "mac/arm64/appcast.xml"])
        self.assertLess(events.index(("get", "https://cdn.tilr.dev/mac/arm64/" + self.dmg.name), 2), events.index(("put", "mac/arm64/appcast.xml")))

    def test_missing_public_archive_retries_and_never_publishes_feed(self):
        candidate = self.root / "appcast.xml"
        candidate.write_bytes(feed())
        with patch.object(publish, "fetch", return_value=False) as fetch, \
             patch.object(publish, "put") as put, patch.object(publish.time, "sleep") as sleep:
            with self.assertRaisesRegex(ValueError, "public URL still returns HTTP 404"):
                publish.upload_verified_assets(self.meta, self.dmg, candidate, self.root)
        self.assertEqual(fetch.call_count, 8)
        self.assertEqual(sleep.call_count, 6)
        self.assertEqual(put.call_count, 1)
        self.assertTrue(put.call_args.args[1].endswith(".dmg"))

    def test_probe_does_not_poison_canonical_url_and_waits_for_old_404(self):
        candidate = self.root / "appcast.xml"
        candidate.write_bytes(feed())
        events = []
        canonical_gets = 0
        def fetch(url, target):
            nonlocal canonical_gets
            events.append(("get", url))
            parts = publish.urlsplit(url)
            if parts.path.endswith(".dmg"):
                if parts.query:
                    return False
                canonical_gets += 1
                if canonical_gets <= 2:
                    return False
                target.write_bytes(b"dmg")
                return True
            if ("put", "mac/arm64/appcast.xml") in events:
                target.write_bytes(candidate.read_bytes())
                return True
            return False
        with patch.object(publish, "fetch", side_effect=fetch), \
             patch.object(publish, "put", side_effect=lambda p, key, *a: events.append(("put", key))), \
             patch.object(publish.time, "sleep") as sleep:
            publish.upload_verified_assets(self.meta, self.dmg, candidate, self.root)
        self.assertIn("?tilr-release-probe=", events[0][1])
        self.assertEqual(events[1], ("put", "mac/arm64/" + self.dmg.name))
        self.assertEqual(canonical_gets, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertLess(events.index(("get", self.meta["feed"].rsplit("/", 1)[0] + "/" + self.dmg.name)),
                        events.index(("put", "mac/arm64/appcast.xml")))

    def test_uploaded_archive_checksum_error_is_explicit(self):
        candidate = self.root / "appcast.xml"
        candidate.write_bytes(feed())
        calls = 0
        def fetch(url, target):
            nonlocal calls
            calls += 1
            target.write_bytes(b"corrupt")
            return calls > 1
        with patch.object(publish, "fetch", side_effect=fetch), patch.object(publish, "put") as put:
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                publish.upload_verified_assets(self.meta, self.dmg, candidate, self.root)
        self.assertEqual(put.call_count, 1)

    def test_damaged_remote_dmg_never_changes_feed(self):
        candidate = self.root / "appcast.xml"
        candidate.write_bytes(feed())
        def fetch(url, target):
            target.write_bytes(b"corrupt")
            return True
        with patch.object(publish, "fetch", side_effect=fetch), patch.object(publish, "put") as put:
            with self.assertRaises(ValueError):
                publish.upload_verified_assets(self.meta, self.dmg, candidate, self.root)
            put.assert_not_called()

    def test_resume_already_published_verifies_without_upload(self):
        def fetch(url, target):
            target.write_bytes(b"dmg" if publish.urlsplit(url).path.endswith(".dmg") else feed())
            return True
        with patch.object(publish, "ROOT", self.root), \
             patch.object(sys, "argv", ["publish.py", str(self.root), "--publish"]), \
             patch.object(publish, "fetch", side_effect=fetch), \
             patch.object(publish, "run"), \
             patch.object(publish.subprocess, "check_output", return_value="public\n"), \
             patch.object(publish, "put") as put:
            publish.main()
        put.assert_not_called()
        receipt = json.loads((self.root / "published.json").read_text())
        self.assertEqual(receipt["build"], 2)

    def test_resume_with_different_public_archive_has_no_receipt(self):
        def fetch(url, target):
            target.write_bytes(b"different" if publish.urlsplit(url).path.endswith(".dmg") else feed())
            return True
        with patch.object(publish, "ROOT", self.root), \
             patch.object(sys, "argv", ["publish.py", str(self.root), "--publish"]), \
             patch.object(publish, "fetch", side_effect=fetch), \
             patch.object(publish, "run"), \
             patch.object(publish.subprocess, "check_output", return_value="public\n"), \
             self.assertRaises(ValueError):
            publish.main()
        self.assertFalse((self.root / "published.json").exists())

    def test_upload_is_an_s3_copy_to_the_r2_bucket(self):
        with patch.object(publish, "run") as run:
            publish.put(Path("/tmp/Tilr.dmg"), "mac/arm64/Tilr.dmg", "application/x-apple-diskimage", "immutable")
        self.assertEqual(run.call_args.args, (
            "aws", "s3", "cp", Path("/tmp/Tilr.dmg"), "s3://tilr-cdn/mac/arm64/Tilr.dmg",
            "--endpoint-url", "https://8e0530af975a33f2f739127f75084531.r2.cloudflarestorage.com",
            "--region", "auto", "--content-type", "application/x-apple-diskimage", "--cache-control", "immutable"))


if __name__ == "__main__":
    unittest.main()
