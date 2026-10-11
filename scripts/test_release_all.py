import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import release_all


class ReleaseAllTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {"TILR_UPDATE_PUBLIC_KEY": "public"}

    def test_both_builds_then_both_preparations_then_publications(self):
        calls = []
        with patch.object(release_all, "completed"):
            release_all.execute("0.1.0", 1, "stable", self.config, publish=True, root=self.root,
                                runner=lambda cmd, **kw: calls.append((cmd, kw)))
        self.assertEqual(len(calls), 6)
        for index, arch in enumerate(("arm64", "x86_64")):
            cmd, kw = calls[index]
            self.assertEqual(cmd[-1], arch)
            self.assertNotIn("--publish", cmd)
            self.assertEqual(kw["env"]["TILR_UPDATE_FEED"], f"https://cdn.tilr.dev/mac/{arch}/appcast.xml")
        self.assertTrue(all("--publish" not in cmd for cmd, _ in calls[2:4]))
        self.assertTrue(all("--publish" in cmd for cmd, _ in calls[4:]))

    def test_second_build_failure_publishes_nothing(self):
        calls = []
        def runner(cmd, **kwargs):
            calls.append(cmd)
            if cmd[-1] == "x86_64":
                raise RuntimeError("Intel build failed")
        with patch.object(release_all, "completed"), self.assertRaises(RuntimeError):
            release_all.execute("0.1.0", 1, "stable", self.config, publish=True, root=self.root, runner=runner)
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(Path(cmd[1]).name == "release.py" for cmd in calls))

    def test_resume_reuses_both_builds_but_checks_them(self):
        for arch in release_all.ARCHES:
            (self.root / "build/releases" / f"0.1.0-1-{arch}").mkdir(parents=True)
        calls = []
        with patch.object(release_all, "completed") as check:
            release_all.execute("0.1.0", 1, "beta", self.config, resume=True, root=self.root,
                                runner=lambda cmd, **kw: calls.append(cmd))
        self.assertFalse(calls)
        self.assertEqual(check.call_count, 2)
        self.assertIn("/mac/beta/x86_64/", check.call_args.args[4])

    def test_second_feed_preparation_failure_publishes_nothing(self):
        calls = []
        def runner(cmd, **kwargs):
            calls.append(cmd)
            if len(calls) == 4:
                raise RuntimeError("Intel feed failed")
        with patch.object(release_all, "completed"), self.assertRaises(RuntimeError):
            release_all.execute("0.1.0", 1, "stable", self.config, publish=True, root=self.root, runner=runner)
        self.assertTrue(all("--publish" not in cmd for cmd in calls))

    def test_publish_only_never_builds(self):
        for arch in release_all.ARCHES:
            (self.root / "build/releases" / f"0.1.0-1-{arch}").mkdir(parents=True)
        calls = []
        with patch.object(release_all, "completed"):
            release_all.execute("0.1.0", 1, "stable", self.config, publish=True, publish_only=True,
                                root=self.root, runner=lambda cmd, **kw: calls.append(cmd))
        self.assertEqual(len(calls), 4)
        self.assertTrue(all(Path(cmd[1]).name == "publish.py" for cmd in calls))

    def test_publish_only_missing_intel_fails_before_upload(self):
        (self.root / "build/releases/0.1.0-1-arm64").mkdir(parents=True)
        calls = []
        with patch.object(release_all, "completed"), self.assertRaisesRegex(ValueError, "never builds"):
            release_all.execute("0.1.0", 1, "stable", self.config, publish=True, publish_only=True,
                                root=self.root, runner=lambda cmd, **kw: calls.append(cmd))
        self.assertFalse(calls)


class AutomaticReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.1", "CFBundleVersion": "1"}))

    def test_reservations_increment_even_without_completed_outputs(self):
        self.assertEqual(release_all.automatic_release(self.root), ("0.1", 2))
        self.assertEqual(release_all.automatic_release(self.root), ("0.1", 3))

    def test_incomplete_and_preview_outputs_are_not_reused(self):
        for name in ("0.1.0-8-arm64", "0.1.0-10-arm64-preview", "0.1.0-7-x86_64"):
            (self.root / "build/releases" / name).mkdir(parents=True)
        self.assertEqual(release_all.automatic_release(self.root), ("0.1.0", 11))

    def test_version_override_is_remembered(self):
        self.assertEqual(release_all.automatic_release(self.root, "0.2.0"), ("0.2.0", 2))
        self.assertEqual(release_all.automatic_release(self.root), ("0.2.0", 3))

    def test_numeric_version_order(self):
        for name in ("0.9.0-20-arm64", "0.10.0-21-arm64"):
            (self.root / "build/releases" / name).mkdir(parents=True)
        self.assertEqual(release_all.automatic_release(self.root), ("0.10.0", 22))

    def test_bad_state_fails_instead_of_reusing_build(self):
        state = self.root / "build/release-auto.json"
        state.parent.mkdir()
        state.write_text("broken")
        with self.assertRaises(ValueError):
            release_all.automatic_release(self.root)

    def test_invalid_override_does_not_reserve(self):
        with self.assertRaises(ValueError):
            release_all.automatic_release(self.root, "invalid")
        self.assertFalse((self.root / "build/release-auto.json").exists())


if __name__ == "__main__":
    unittest.main()
