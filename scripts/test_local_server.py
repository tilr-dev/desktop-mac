"""Exercise production host configuration transitions in an isolated app fixture."""
from pathlib import Path
import os
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
service) test "$2" = install; cp "$state/installed" "$state/running";;
*) exit 1;;
esac
''')
            cli.chmod(0o755)
            subprocess.run(["swiftc", str(ROOT / "Sources/Tilr/ServerInstallation.swift"),
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


if __name__ == "__main__":
    unittest.main()
