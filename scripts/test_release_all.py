import io
import os
import shutil
from contextlib import ExitStack
import release
from contextlib import redirect_stdout
import plistlib
import json
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

    def test_channels_package_identical_plists_with_only_receipt_routing(self):
        template = (release.ROOT / "Info.plist").read_bytes()
        outputs = {}
        for channel in ("stable", "beta"):
            root = self.root / channel
            root.mkdir()
            (root / "Info.plist").write_bytes(template)
            (root / "Resources").mkdir()
            (root / "Resources/AppIcon.icns").write_bytes(b"icon")
            (root / "placeholder.html").write_text("placeholder")
            binary_dir = root / "binary"
            binary_dir.mkdir()
            (binary_dir / "Tilr").write_bytes(b"compiled app")
            framework = root / "framework"
            framework.mkdir()
            config = dict(TILR_UPDATE_PUBLIC_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                          TILR_SIGN_IDENTITY="Developer ID Application: Test",
                          TILR_NOTARY_PROFILE="test-profile")

            def platform_run(*args, **kwargs):
                args = list(map(str, args))
                if args[0] == "ditto":
                    if "-c" in args:
                        Path(args[-1]).write_bytes(b"notarization archive")
                    elif Path(args[1]).is_dir():
                        shutil.copytree(args[1], args[2])
                    else:
                        shutil.copy2(args[1], args[2])
                elif args[:2] == ["hdiutil", "create"]:
                    Path(args[-1]).write_bytes(b"completed dmg")

            def runner(command, env):
                argv = [str(x) for x in command[1:]] + ["--skip-build", "--framework", str(framework)]
                with patch.object(release.sys, "argv", argv), patch.dict(os.environ, env, clear=True):
                    release.main()

            previous_cwd = Path.cwd()
            try:
                with ExitStack() as stack, redirect_stdout(io.StringIO()):
                    stack.enter_context(patch.object(release, "ROOT", root))
                    stack.enter_context(patch.object(release, "run", side_effect=platform_run))
                    stack.enter_context(patch.object(release.subprocess, "check_output", side_effect=
                        lambda cmd, **kw: str(binary_dir) if "--show-bin-path" in cmd else "checksum"))
                    for name in ("strip_executable", "embed_framework", "audit", "sign", "size_report"):
                        stack.enter_context(patch.object(release, name))
                    for name in ("bundle_plugins", "verify_plugin_publishers"):
                        stack.enter_context(patch("bundle_plugins." + name))
                    stack.enter_context(patch("bundle_plugins.plugin_inventory", return_value=[]))
                    stack.enter_context(patch("bundle_server.bundle_server", return_value=
                        dict(protocolVersion=1, build=1, version="0.1.0")))
                    stack.enter_context(patch.object(release_all, "completed", return_value=[]))
                    directories = release_all.execute("0.1.0", 1, channel, config, root=root, runner=runner)
                outputs[channel] = []
                for directory in directories:
                    data = (directory / "Tilr.app/Contents/Info.plist").read_bytes()
                    info = plistlib.loads(data)
                    self.assertNotIn("SUFeedURL", info)
                    self.assertEqual(info["TilrUpdateFeedSelection"], "preferences")
                    receipt = json.loads((directory / "release.json").read_text())
                    self.assertEqual(receipt["feed"], release_all.feed_for(receipt["arch"], channel))
                    outputs[channel].append(data)
            finally:
                os.chdir(previous_cwd)
        self.assertEqual(outputs["stable"], outputs["beta"])

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

    def test_plugin_version_mismatch_prevents_publication(self):
        calls = []
        with patch.object(release_all, 'completed', side_effect=[
                [('audio', '0.1.0', 1)], [('audio', '0.1.1', 1)]]), \
             self.assertRaisesRegex(ValueError, 'Native plugin versions'):
            release_all.execute('0.1.0', 1, 'stable', self.config, publish=True, root=self.root,
                                runner=lambda cmd, **kw: calls.append(cmd))
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(Path(cmd[1]).name == 'release.py' for cmd in calls))

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

    def test_status_does_not_reserve(self):
        self.assertEqual(release_all.automatic_release(self.root, reserve=False), ("0.1", 2))
        self.assertFalse((self.root / "build/release-auto.json").exists())

    def test_explicit_build_is_reserved_and_next_run_increments(self):
        self.assertEqual(release_all.automatic_release(self.root, build=20), ("0.1", 20))
        self.assertEqual(release_all.automatic_release(self.root), ("0.1", 21))
        with self.assertRaisesRegex(ValueError, "already used or reserved"):
            release_all.automatic_release(self.root, build=20)

    def test_missing_pinned_server_builds_only_missing_arch(self):
        (self.root / "server-release.json").write_text(json.dumps(dict(version="0.1.0", build=1)))
        existing = self.root / "build/server-releases/0.1.0-1-arm64"
        existing.mkdir(parents=True)
        (existing / "release.json").write_text("{}")
        calls = []
        with patch.dict(release_all.os.environ, {}, clear=True):
            release_all.ensure_server(self.root, runner=lambda cmd: calls.append(cmd))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-2:], ["--arch", "x86_64"])
        (existing / "release.json").unlink()
        with patch.dict(release_all.os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "Incomplete"):
            release_all.ensure_server(self.root, runner=lambda cmd: self.fail("Must not build"))

    def test_latest_upload_uses_completed_pair_without_building(self):
        saved = self.root / "build/latest-app-release.json"
        saved.parent.mkdir()
        saved.write_text(json.dumps(dict(version="0.2.0", build=9, channel="beta")))
        outputs = []
        for arch in release_all.ARCHES:
            output = self.root / arch
            output.mkdir()
            (output / "published.json").write_text(json.dumps(dict(download="https://example.com/" + arch)))
            outputs.append(output)
        (self.root / "build/releases").mkdir()
        with patch.object(release_all, "ROOT", self.root), \
             patch.object(release_all.sys, "argv", ["release_all.py", "--latest", "--publish-only"]), \
             patch.object(release_all, "settings", return_value={}), \
             patch.object(release_all, "preflight"), \
             patch.object(release_all, "execute", return_value=outputs) as execute, \
             patch.object(release_all, "ensure_server") as server:
            release_all.main()
        self.assertEqual(execute.call_args.args[:3], ("0.2.0", 9, "beta"))
        self.assertTrue(execute.call_args.kwargs["publish_only"])
        server.assert_not_called()

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

    def test_dev_placeholder_template_is_ignored(self):
        (self.root / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.0.0-dev", "CFBundleVersion": "1"}))
        with self.assertRaisesRegex(ValueError, "pass --version"):
            release_all.automatic_release(self.root)
        self.assertFalse((self.root / "build/release-auto.json").exists())
        self.assertEqual(release_all.automatic_release(self.root, version="0.3.0", reserve=False), ("0.3.0", 2))
        (self.root / "build/releases/0.2.0-16-arm64").mkdir(parents=True)
        self.assertEqual(release_all.automatic_release(self.root), ("0.2.0", 17))

    def test_status_with_no_release_version_does_not_reserve(self):
        (self.root / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.0.0-dev", "CFBundleVersion": "1"}))
        (self.root / "server-release.json").write_text(json.dumps({
            "version": "0.1.0", "build": 1, "protocolVersion": 1}))
        output = io.StringIO()
        with redirect_stdout(output):
            release_all.show_status(self.root)
        self.assertIn("No release version yet; pass --version", output.getvalue())
        self.assertIn("highest local/reserved build: 1", output.getvalue())
        self.assertFalse((self.root / "build").exists())

    def test_first_auto_release_accepts_explicit_version(self):
        (self.root / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.0.0-dev", "CFBundleVersion": "1"}))
        (self.root / "server-release.json").write_text(json.dumps({
            "version": "0.1.0", "build": 1, "protocolVersion": 1}))
        with patch.object(release_all, "ROOT", self.root), \
             patch.object(release_all.sys, "argv", ["release_all.py", "--auto", "--version", "0.3.0"]), \
             patch.object(release_all, "settings", return_value={}), \
             patch.object(release_all, "preflight"), \
             patch.object(release_all, "ensure_server"), \
             patch.object(release_all, "execute", return_value=[]) as execute, redirect_stdout(io.StringIO()):
            release_all.main()
        self.assertEqual(execute.call_args.args[:3], ("0.3.0", 2, "stable"))
        self.assertEqual(json.loads((self.root / "build/release-auto.json").read_text()),
                         {"version": "0.3.0", "build": 2})

    def test_invalid_override_does_not_reserve(self):
        with self.assertRaises(ValueError):
            release_all.automatic_release(self.root, "invalid")
        self.assertFalse((self.root / "build/release-auto.json").exists())

    def preflight_asks_sparkle(self, key, publish):
        tools = self.root / ".build/artifacts/sparkle/Sparkle/bin"
        tools.mkdir(parents=True)
        (tools / "generate_keys").touch()
        (self.root / "build").mkdir()
        config = {"TILR_SIGN_IDENTITY": "Developer ID Application: Test", "TILR_NOTARY_PROFILE": "profile",
                  "TILR_UPDATE_PUBLIC_KEY": "public"}
        asked = []
        def check_output(command, **kwargs):
            asked.append(command)
            if command[0] == "security":
                return '  1) ABC "Developer ID Application: Test"\n'
            return key + "\n"
        with patch.object(release_all, "ROOT", self.root), \
             patch.object(release_all.shutil, "which", return_value="/usr/bin/tool"), \
             patch.object(release_all.subprocess, "check_output", side_effect=check_output), \
             patch.object(release_all, "run"), patch.object(release_all, "sign"), \
             redirect_stdout(io.StringIO()):
            release_all.preflight(config, publish, build=True)
        return any(str(command[0]).endswith("generate_keys") for command in asked)

    def test_build_only_preflight_needs_no_sparkle_private_key(self):
        self.assertFalse(self.preflight_asks_sparkle("", publish=False))

    def test_publishing_preflight_checks_the_sparkle_key(self):
        self.assertTrue(self.preflight_asks_sparkle("public", publish=True))

    def test_publishing_preflight_checks_the_r2_bucket(self):
        tools = self.root / ".build/artifacts/sparkle/Sparkle/bin"
        tools.mkdir(parents=True)
        (tools / "generate_keys").touch()
        config = {"TILR_UPDATE_PUBLIC_KEY": "public"}
        with patch.object(release_all, "ROOT", self.root), \
             patch.object(release_all.shutil, "which", return_value="/usr/bin/tool"), \
             patch.object(release_all.subprocess, "check_output", return_value="public\n"), \
             patch.object(release_all, "run") as run, redirect_stdout(io.StringIO()):
            release_all.preflight(config, True, build=False)
        self.assertEqual(run.call_args.args[0][:4], ["aws", "s3api", "head-bucket", "--bucket"])
        self.assertIn("https://8e0530af975a33f2f739127f75084531.r2.cloudflarestorage.com", run.call_args.args[0])

    def test_publishing_preflight_rejects_another_sparkle_key(self):
        with self.assertRaisesRegex(ValueError, "Sparkle key"):
            self.preflight_asks_sparkle("other", publish=True)


if __name__ == "__main__":
    unittest.main()
