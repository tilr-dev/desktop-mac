import io
import os
import shutil
from contextlib import ExitStack
import release
from contextlib import redirect_stdout, redirect_stderr
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

    def test_obsolete_local_options_are_rejected_before_side_effects(self):
        for option in ("--auto", "--status", "--latest", "--publish", "--publish-only", "--notes"):
            for module in (release_all, release):
                if module is release and option not in ("--publish", "--notes"):
                    continue
                with self.subTest(module=module.__name__, option=option), \
                     patch.object(module.sys, "argv", [module.__file__, "--version", "0.1.0", "--build", "1", option]), \
                     patch.object(module, "run") as run, patch.object(release_all, "settings") as settings, \
                     redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stopped:
                    module.main()
                self.assertEqual(stopped.exception.code, 2)
                run.assert_not_called()
                settings.assert_not_called()

    def test_packaging_requires_explicit_metadata_before_preflight(self):
        for arguments in ([], ["--version", "0.1.0"], ["--build", "1"],
                          ["--version", "invalid", "--build", "1"], ["--version", "0.1.0", "--build", "0"]):
            with self.subTest(arguments=arguments), \
                 patch.object(release_all.sys, "argv", ["release_all.py", *arguments]), \
                 patch.object(release_all, "settings") as settings, \
                 redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stopped:
                release_all.main()
            self.assertEqual(stopped.exception.code, 2)
            settings.assert_not_called()

    def test_access_check_only_runs_build_preflight(self):
        with patch.object(release_all, "ROOT", self.root), \
             patch.object(release_all.sys, "argv", ["release_all.py", "--check"]), \
             patch.object(release_all, "settings", return_value=self.config), \
             patch.object(release_all, "preflight") as preflight, patch.object(release_all, "execute") as execute:
            release_all.main()
        preflight.assert_called_once_with(self.config, publish=False)
        execute.assert_not_called()
        self.assertEqual(list((self.root / "build").iterdir()), [])

    def test_settings_require_environment_without_local_config_fallback(self):
        key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        (self.root / "release.local.json").write_text(json.dumps({
            "TILR_SIGN_IDENTITY": "Developer ID Application: Test",
            "TILR_NOTARY_PROFILE": "local", "TILR_UPDATE_PUBLIC_KEY": key}))
        with patch.object(release_all, "ROOT", self.root), patch.dict(os.environ, {}, clear=True), \
             self.assertRaisesRegex(ValueError, "Missing release environment settings"):
            release_all.settings()
        with patch.dict(os.environ, {"TILR_UPDATE_PUBLIC_KEY": key}, clear=True):
            self.assertEqual(release_all.settings(require_build=False)["TILR_UPDATE_PUBLIC_KEY"], key)

    def test_shared_ci_publisher_prepares_both_feeds_before_publication(self):
        calls = []
        outputs = [self.root / arch for arch in release_all.ARCHES]
        release_all.publish_pair(outputs, notes=self.root / "notes", root=self.root, runner=lambda cmd: calls.append(cmd))
        self.assertEqual([cmd[2] for cmd in calls], outputs * 2)
        self.assertEqual(["--publish" in cmd for cmd in calls], [False, False, True, True])
        self.assertTrue(all(cmd[3:5] == ["--notes", str(self.root / "notes")] for cmd in calls))

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
                    self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")
                    self.assertTrue((directory / f"Tilr-0.1.0-1-{directory.name.rsplit('-', 1)[1]}.dmg").is_file())
                    self.assertNotIn("SUFeedURL", info)
                    self.assertEqual(info["TilrUpdateFeedSelection"], "preferences")
                    receipt = json.loads((directory / "release.json").read_text())
                    self.assertEqual(receipt["feed"], release_all.feed_for(receipt["arch"], channel))
                    outputs[channel].append(data)
            finally:
                os.chdir(previous_cwd)
        self.assertEqual(outputs["stable"], outputs["beta"])

    def test_second_build_failure_stops_packaging(self):
        calls = []
        def runner(cmd, **kwargs):
            calls.append(cmd)
            if cmd[-1] == "x86_64":
                raise RuntimeError("Intel build failed")
        with patch.object(release_all, "completed"), self.assertRaises(RuntimeError):
            release_all.execute("0.1.0", 1, "beta", self.config, root=self.root, runner=runner)
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(Path(cmd[1]).name == "release.py" for cmd in calls))

    def test_plugin_version_mismatch_rejects_pair(self):
        calls = []
        with patch.object(release_all, 'completed', side_effect=[
                [('audio', '0.1.0', 1)], [('audio', '0.1.1', 1)]]), \
             self.assertRaisesRegex(ValueError, 'Native plugin versions'):
            release_all.execute('0.1.0', 1, 'beta', self.config, root=self.root,
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
        def runner(cmd):
            calls.append(cmd)
            if len(calls) == 2:
                raise RuntimeError("Intel feed failed")
        with self.assertRaises(RuntimeError):
            release_all.publish_pair([self.root / arch for arch in release_all.ARCHES], runner=runner)
        self.assertTrue(all("--publish" not in cmd for cmd in calls))


if __name__ == "__main__":
    unittest.main()
