"""Exercise production host configuration transitions in an isolated app fixture."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalServerIntegrationTests(unittest.TestCase):
    def test_application_uninstall(self):
        with tempfile.TemporaryDirectory(prefix="tilr-uninstall-") as temp:
            binary = Path(temp) / "test-uninstall"
            subprocess.run(["swiftc", str(ROOT / "Sources/Tilr/ServerInstallation.swift"),
                            str(ROOT / "Sources/Tilr/AppUninstall.swift"),
                            str(ROOT / "scripts/test_app_uninstall.swift"), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("application uninstall tests passed", result.stdout)

    def test_disable_then_reenable_shared_server(self):
        with tempfile.TemporaryDirectory(prefix="tilr-host-") as temp:
            contents = Path(temp) / "Fixture.app/Contents"
            binary = contents / "MacOS/Fixture"
            binary.parent.mkdir(parents=True)
            helpers = contents / "Helpers"
            helpers.mkdir()
            resources = contents / "Resources/server"
            resources.mkdir(parents=True)
            (resources / "app-managed.json").write_text("{}")
            info = dict(CFBundleIdentifier="dev.tilr.host-fixture", CFBundleExecutable="Fixture",
                        CFBundleVersion="10", TilrServerProtocolVersion=1)
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            cli = helpers / "tilr"
            cli.write_text('''#!/bin/sh
set -eu
[ "$1" = --socket ] && shift 2
case "$1" in
version) echo 'tilr 1.0.0-abc (macos-aarch64)'; echo 'tilrd 1.0.0-abc at local';;
token) echo shared-token;;
*) exit 1;;
esac
''')
            cli.chmod(0o755)
            subprocess.run(["swiftc", str(ROOT / "Sources/Tilr/ServerInstallation.swift"),
                            str(ROOT / "Sources/Tilr/ServerUpdates.swift"),
                            str(ROOT / "Sources/Tilr/LocalServer.swift"),
                            str(ROOT / "scripts/test_local_server.swift"), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("local server enable-disable-enable passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
