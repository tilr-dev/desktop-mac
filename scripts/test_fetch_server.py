import hashlib
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import bundle_server
import fetch_server
import release_server


class UpstreamServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'server-release.json').write_text(json.dumps(dict(version='0.2.0', build=4, protocolVersion=1)))
        self.remote = {}
        self.binaries = {}
        self.commands = []
        self.signature = f'Authority=Developer ID Application: Rexuni ({fetch_server.TEAM})\nTeamIdentifier={fetch_server.TEAM}\nTimestamp=Oct 27, 2026\n'
        for arch in fetch_server.TARGETS:
            self.archive(arch)

    def archive(self, arch, unsafe=None, version="0.2.0-abcdef0"):
        url = fetch_server.release_url('0.2.0', arch)
        cpu = 'aarch64' if arch == 'arm64' else arch
        binary = f"#!/bin/sh\nprintf 'tilrd {version} (macos-{cpu})\\n'\n".encode()
        self.binaries[arch] = binary
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as tar:
            top = Path(url).name.removesuffix('.tar.gz')
            for name, content in [('tilrd', binary), ('tilr', b'client'), ('LICENSE-MIT', b'license')]:
                entry = tarfile.TarInfo(f'{top}/{name}')
                entry.size = len(content)
                tar.addfile(entry, io.BytesIO(content))
            if unsafe:
                entry = tarfile.TarInfo(unsafe)
                entry.type = tarfile.SYMTYPE
                entry.linkname = '/tmp/outside'
                tar.addfile(entry)
        self.remote[url] = data.getvalue()
        self.remote[url + '.sha256'] = (hashlib.sha256(data.getvalue()).hexdigest() + '  ' + Path(url).name + '\n').encode()

    def fetch(self, url, path):
        if url not in self.remote:
            return False
        path.write_bytes(self.remote[url])
        return True

    def command_run(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == 'ditto':
            shutil.copyfile(command[1], command[2])
        elif command[0] != 'codesign':
            raise AssertionError(command)
        return subprocess.CompletedProcess(command, 0, stderr=self.signature)

    def patches(self):
        from contextlib import ExitStack
        stack = ExitStack()
        stack.enter_context(patch.object(fetch_server, 'ROOT', self.root))
        stack.enter_context(patch.object(fetch_server, 'fetch', self.fetch))
        stack.enter_context(patch.object(fetch_server.subprocess, 'run', self.command_run))
        # check_output internally calls run, so native execution is explicitly handled below.
        stack.enter_context(patch.object(fetch_server.subprocess, 'check_output', self.output))
        stack.enter_context(patch.object(fetch_server.platform, 'machine', return_value='arm64'))
        stack.enter_context(patch('sys.argv', ['fetch_server.py', '--public-key', 'public']))
        stack.enter_context(redirect_stdout(io.StringIO()))
        return stack

    def output(self, command, **kwargs):
        self.commands.append(command)
        binary = Path(command[-1] if command[0] == 'lipo' else command[0]).read_bytes()
        arch = 'arm64' if b'macos-aarch64' in binary else 'x86_64'
        if command[0] == 'lipo':
            return arch + '\n'
        self.assertEqual(command[1:], ['--version'])
        self.assertEqual(arch, 'arm64', 'Foreign architecture must not be executed')
        return 'tilrd 0.2.0-abcdef0 (macos-aarch64)\n'

    def main(self):
        with self.patches():
            return fetch_server.main()

    def test_import_bundle_and_publish_validation_preserve_signed_bytes(self):
        self.assertEqual(self.main(), 0)
        for arch in fetch_server.TARGETS:
            path = self.root / f'build/server-releases/0.2.0-4-{arch}'
            with self.patches():
                manifest = release_server.validated(path, '0.2.0', 4, arch, 'public')
                bundle_server.bundle_server(self.root / f'{arch}.app', arch, 17, root=self.root)
            self.assertEqual(manifest['serverVersion'], '0.2.0-abcdef0')
            self.assertEqual((path / 'tilrd').read_bytes(), self.binaries[arch])
            self.assertEqual((self.root / f'{arch}.app/Contents/Helpers/tilrd').read_bytes(), self.binaries[arch])
            receipt = json.loads((path / 'release.json').read_text())
            self.assertEqual(receipt['upstream']['url'], fetch_server.release_url('0.2.0', arch))
        requirements = [c[c.index('-R') + 1] for c in self.commands if '-R' in c]
        self.assertTrue(requirements)
        self.assertTrue(all('anchor apple generic' in r and '100.6.1.13' in r for r in requirements))
        self.assertFalse(any('--sign' in c or c[0] in ('cargo', 'xcrun', 'strip') for c in self.commands))
        self.assertEqual(self.main(), 0)  # Reuse validates, never overwrites.

    def test_missing_asset_has_no_build_fallback_or_completed_output(self):
        del self.remote[fetch_server.release_url('0.2.0', 'x86_64')]
        with self.assertRaisesRegex(ValueError, 'Missing upstream'):
            self.main()
        self.assertFalse((self.root / 'build').exists())

    def test_bad_checksum_fails_before_signature_or_execution(self):
        url = fetch_server.release_url('0.2.0', 'arm64')
        self.remote[url] += b'changed'
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            self.main()
        self.assertEqual(self.commands, [])

    def test_archive_path_or_symlink_is_rejected(self):
        for name in ('../tilrd', '/tmp/tilrd', 'tilr-v0.2.0-aarch64-apple-darwin/link'):
            with self.subTest(name=name):
                self.archive('arm64', unsafe=name)
                with self.assertRaisesRegex(ValueError, 'Unsafe'):
                    self.main()
        self.assertFalse((self.root / 'build').exists())

    def test_other_team_adhoc_and_missing_timestamp_are_rejected_before_execution(self):
        for details in ('TeamIdentifier=OTHER\nTimestamp=t\n',
                        f'TeamIdentifier={fetch_server.TEAM}\nTimestamp=t\n',
                        self.signature.replace('Timestamp=Oct 27, 2026\n', '')):
            with self.subTest(details=details):
                self.signature = details
                with self.assertRaisesRegex(ValueError, 'Developer ID'):
                    self.main()
        self.assertFalse(any(c[1:] == ['--version'] for c in self.commands))

    def test_wrong_architecture_and_version_fail(self):
        with self.patches(), patch.object(fetch_server.subprocess, 'check_output', return_value='x86_64\n'):
            with self.assertRaisesRegex(ValueError, 'architecture'):
                fetch_server.main()
        self.archive('arm64', version='0.2.0-build4-abcdef0')
        # A correctly checksummed fixture still must use the upstream release identity.
        with self.assertRaisesRegex(ValueError, 'release version/platform'):
            self.main()
        self.assertFalse((self.root / 'build').exists())

    def test_cached_tampering_and_legacy_compiled_receipt_are_rejected(self):
        self.main()
        path = self.root / 'build/server-releases/0.2.0-4-arm64'
        (path / 'tilrd').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'changed after'):
            self.main()
        receipt = json.loads((path / 'release.json').read_text())
        receipt.pop('upstream')
        (path / 'release.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'completed upstream'):
            self.main()


if __name__ == '__main__':
    unittest.main()
