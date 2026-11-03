"""Exercise production host configuration transitions in an isolated app fixture."""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalServerIntegrationTests(unittest.TestCase):
    def test_config_file_bridge(self):
        with tempfile.TemporaryDirectory(prefix="tilr-config-") as temp:
            binary = Path(temp) / "test-config-files"
            subprocess.run(["swiftc", str(ROOT / "Sources/Tilr/ConfigFiles.swift"),
                            str(ROOT / "scripts/TestSupport.swift"),
                            str(ROOT / "scripts/test_config_files.swift"), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
            self.assertIn("config file validation and IO tests passed", result.stdout)

    def test_trusted_config_webkit_bridge(self):
        with tempfile.TemporaryDirectory(prefix="tilr-config-bridge-") as temp:
            binary = Path(temp) / "test-config-bridge"
            subprocess.run(["swiftc", str(ROOT / "Sources/Tilr/ConfigFiles.swift"),
                            str(ROOT / "Sources/Tilr/ConfigBridge.swift"),
                            str(ROOT / "Sources/Tilr/FolderWatcher.swift"),
                            str(ROOT / "scripts/TestSupport.swift"),
                            str(ROOT / "scripts/test_config_bridge.swift"), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True, check=True, timeout=30)
            self.assertIn("trusted config WebKit bridge tests passed", result.stdout)

    def test_application_uninstall(self):
        with tempfile.TemporaryDirectory(prefix="tilr-uninstall-") as temp:
            binary = Path(temp) / "test-uninstall"
            subprocess.run(["swiftc", str(ROOT / "Sources/Tilr/ServerInstallation.swift"),
                            str(ROOT / "scripts/TestSupport.swift"),
                            str(ROOT / "Sources/Tilr/AppUninstall.swift"),
                            str(ROOT / "scripts/test_app_uninstall.swift"), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("application uninstall tests passed", result.stdout)

    def test_disable_then_reenable_shared_server(self):
        with tempfile.TemporaryDirectory(prefix="tilr-host-") as temp:
            contents = Path(temp) / "Fixture.app/Contents"
            binary = contents / "MacOS/Fixture"
            binary.parent.mkdir(parents=True)
            helpers = contents / "Helpers"
            helpers.mkdir()
            (helpers / "tilrd").write_text("#!/bin/sh\nexit 1\n")
            info = dict(CFBundleIdentifier="dev.tilr.host-fixture", CFBundleExecutable="Fixture",
                        CFBundleVersion="10", TilrServerProtocolVersion=1)
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            cli = helpers / "tilr"
            cli.write_text('''#!/bin/sh
set -eu
state="$TILR_HOST_FIXTURE"
[ "$1" = --socket ] && shift 2
case "$1" in
version)
    if [ -f "$state/running" ]; then
        if [ -f "$state/newer" ]; then echo 'tilr: the server speaks protocol 2, tilr 1' >&2; exit 2; fi
        if [ -f "$state/incompatible" ]; then echo 'tilr: the server speaks protocol 0, tilr 1' >&2; exit 2; fi
        echo "tilrd $(cat "$state/running") at local"
    else echo 'tilrd is not running at local'; fi;;
token) test -f "$state/running"; cat "$state/token";;
service)
    case "$2" in
    install) cp "$state/installed" "$state/running";;
    uninstall) rm "$state/registered";;
    *) exit 1;;
    esac;;
*) exit 1;;
esac
''')
            cli.chmod(0o755)
            subprocess.run(["swiftc", str(ROOT / "Sources/Tilr/ServerInstallation.swift"),
                            str(ROOT / "scripts/TestSupport.swift"),
                            str(ROOT / "Sources/Tilr/LocalServer.swift"),
                            str(ROOT / "scripts/test_local_server.swift"), "-o", str(binary)], check=True)
            shell = Path(temp) / "empty-shell"
            shell.write_text("#!/bin/sh\nexit 1\n")
            shell.chmod(0o755)
            env = dict(os.environ, TILR_HOST_FIXTURE=temp, SHELL=str(shell),
                       TILR_SOCKET=str(Path(temp) / "isolated.sock"))
            result = subprocess.run([str(binary)], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("local server enable-disable-enable passed", result.stdout)
            self.assertIn("local server daemon updates and protocol recovery passed", result.stdout)
            self.assertIn("local server removal confirmation passed", result.stdout)


class CleanCheckFailureTests(unittest.TestCase):
    def test_no_trapping_check_failures(self):
        import re
        paths = list((ROOT / "scripts").glob("test_*.swift"))
        paths += [ROOT / "Sources/Tilr" / name for name in
                  ("main.swift", "HandoffProbe.swift", "PluginManagerHost.swift")]
        for path in paths:
            with self.subTest(path=path.name):
                self.assertIsNone(re.search(r"\b(?:precondition(?:Failure)?|fatalError|assert)\s*\(",
                                            path.read_text()))

    def test_mutated_uninstall_check_exits_one_with_stderr(self):
        # Mutate a real test assertion, not a production failpoint or test-only flag.
        source = ROOT / "scripts/test_app_uninstall.swift"
        original = 'expect(questions == (owned ? 0 : 1))'
        mutated = source.read_text().replace(original, 'expect(questions == -1, "mutated removal check")', 1)
        self.assertNotEqual(mutated, source.read_text())
        with tempfile.TemporaryDirectory(prefix="tilr-clean-failure-") as temp:
            fixture = Path(temp) / source.name
            fixture.write_text(mutated)
            binary = Path(temp) / "uninstall"
            subprocess.run(["swiftc", "-O", str(ROOT / "Sources/Tilr/ServerInstallation.swift"),
                            str(ROOT / "Sources/Tilr/AppUninstall.swift"),
                            str(ROOT / "scripts/TestSupport.swift"), str(fixture), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertRegex(result.stderr, r"FAIL .*test_app_uninstall\.swift:\d+: mutated removal check\n")
            self.assertNotIn("mutated removal check", result.stdout)

    def test_probe_failure_uses_stderr_and_cleans_up(self):
        with tempfile.TemporaryDirectory(prefix="tilr-probe-failure-") as temp:
            fixture = Path(temp) / "main.swift"
            fixture.write_text('''import Foundation
let probe = ProbeCheck("probe-regression", cleanup: {
    FileHandle.standardError.write(Data("cleanup\\n".utf8))
})
if CommandLine.arguments.contains("throw") {
    probe.attempt { throw NSError(domain: "fixture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "fixture error"]) }
}
probe(false, "mutated probe check")
''')
            binary = Path(temp) / "probe"
            subprocess.run(["swiftc", "-O", str(ROOT / "Sources/Tilr/ProbeFailure.swift"),
                            str(fixture), "-o", str(binary)], check=True)
            for args, diagnostic in (([], "mutated probe check"), (["throw"], "fixture error")):
                with self.subTest(args=args):
                    result = subprocess.run([str(binary), *args], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertRegex(result.stderr, r"probe-regression: FAIL .*main\.swift:\d+: " + diagnostic)
                    self.assertTrue(result.stderr.endswith("\ncleanup\n"), result.stderr)


if __name__ == "__main__":
    unittest.main()
