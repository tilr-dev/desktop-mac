import errno
import hashlib
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import bundle_server
import fetch_server


class UpstreamServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        import plistlib
        (self.root / 'Info.plist').write_bytes(plistlib.dumps(dict(TilrServerProtocolVersion=1)))
        self.remote = {}
        self.release('0.2.0')
        self.binaries = {}
        self.clients = {}
        self.commands = []
        self.requests = []
        self.signature = f'Authority=Developer ID Application: Rexuni ({fetch_server.TEAM})\nTeamIdentifier={fetch_server.TEAM}\nTimestamp=Oct 27, 2026\n'
        for arch in fetch_server.TARGETS:
            self.archive(arch)

    def archive(self, arch, unsafe=None, version="0.2.0-abcdef0", client_version=None, omit_client=False, duplicate_client=False):
        url = fetch_server.release_url('0.2.0', arch)
        cpu = 'aarch64' if arch == 'arm64' else arch
        binary = f"#!/bin/sh\nprintf 'tilrd {version} (macos-{cpu})\\n'\n".encode()
        self.binaries[arch] = binary
        client = f"#!/bin/sh\nprintf 'tilr {client_version or version} (macos-{cpu})\\n'\n".encode()
        self.clients[arch] = client
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as tar:
            top = Path(url).name.removesuffix('.tar.gz')
            contents = [('tilrd', binary), ('LICENSE-MIT', b'license')]
            if not omit_client:
                contents.append(('tilr', client))
            if duplicate_client:
                contents.append(('tilr', client))
            for name, content in contents:
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

    def release(self, version, tag=None, protocol='pub const PROTOCOL_VERSION: u32 = 1;\n'):
        self.remote[fetch_server.LATEST_URL] = json.dumps(dict(tag_name=tag or f'v{version}', prerelease=False)).encode()
        if protocol is None:
            self.remote.pop(fetch_server.protocol_url(version), None)
        else:
            self.remote[fetch_server.protocol_url(version)] = protocol.encode()

    def fetch(self, url, path, headers=()):
        self.requests.append((url, [Path(h[1:]).read_text() if h.startswith('@') else h for h in headers]))
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
        return ('tilr' if binary in self.clients.values() else 'tilrd') + ' 0.2.0-abcdef0 (macos-aarch64)\n'

    def main(self):
        with self.patches():
            return fetch_server.main()

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS codesign')
    def test_real_codesign_parses_inline_requirement_before_rejecting_unsigned_code(self):
        binary = self.root / 'unsigned'
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o755)
        real_run = subprocess.run

        def capture(command, **kwargs):
            return real_run(command, **(kwargs | dict(capture_output=True, text=True)))

        with patch.object(fetch_server.subprocess, 'run', side_effect=capture):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                fetch_server.check_signature(binary)
        self.assertIn('code object is not signed at all', raised.exception.stderr)
        self.assertNotIn('invalid requirement specification', raised.exception.stderr)

    def test_import_and_bundle_validation_preserve_signed_bytes(self):
        self.assertEqual(self.main(), 0)
        for arch in fetch_server.TARGETS:
            path = self.root / f'build/server-releases/0.2.0-{arch}'
            with self.patches():
                manifest = fetch_server.validate_completed(path, '0.2.0', arch, 1, 'public')
                bundle_server.bundle_server(self.root / f'{arch}.app', arch, 1, root=self.root)
            self.assertEqual(manifest['serverVersion'], '0.2.0-abcdef0')
            self.assertEqual((path / 'tilrd').read_bytes(), self.binaries[arch])
            self.assertEqual((self.root / f'{arch}.app/Contents/Helpers/tilrd').read_bytes(), self.binaries[arch])
            self.assertEqual((path / 'tilr').read_bytes(), self.clients[arch])
            self.assertEqual((self.root / f'{arch}.app/Contents/Helpers/tilr').read_bytes(), self.clients[arch])
            client = json.loads((path / 'client.json').read_text())
            self.assertEqual(client['sha256'], hashlib.sha256(self.clients[arch]).hexdigest())
            self.assertEqual(client['version'], manifest['serverVersion'])
            receipt = json.loads((path / 'release.json').read_text())
            self.assertEqual(receipt['upstream']['url'], fetch_server.release_url('0.2.0', arch))
        requirements = [arg[3:] for c in self.commands for arg in c if arg.startswith('-R=')]
        self.assertTrue(requirements)
        self.assertTrue(all('anchor apple generic' in r and '100.6.1.13' in r
                            and '100.6.2.6' in r and fetch_server.TEAM in r for r in requirements))
        self.assertFalse(any('--sign' in c or c[0] in ('cargo', 'xcrun', 'strip') for c in self.commands))
        self.assertEqual(self.main(), 0)  # Reuse validates, never overwrites.

    def test_bundle_rejects_preview_receipts_before_copying(self):
        self.main()
        path = self.root / 'build/server-releases/0.2.0-arm64/release.json'
        receipt = json.loads(path.read_text())
        app = self.root / 'preview.app'
        for preview in (True, None, 0):
            with self.subTest(preview=preview):
                receipt['preview'] = preview
                path.write_text(json.dumps(receipt))
                with self.patches(), self.assertRaisesRegex(ValueError, 'not a completed upstream release'):
                    bundle_server.bundle_server(app, 'arm64', 1, root=self.root)
                self.assertFalse(app.exists())

    def test_local_acquisition_needs_no_release_credentials_and_bundles_exact_bytes(self):
        with self.patches(), patch.dict('os.environ', {}, clear=True):
            self.assertEqual(self.main(), 0)
            for arch in fetch_server.TARGETS:
                bundle_server.bundle_server(self.root / f'{arch}.app', arch, 1, root=self.root)
                self.assertEqual((self.root / f'{arch}.app/Contents/Helpers/tilrd').read_bytes(), self.binaries[arch])
                self.assertEqual((self.root / f'{arch}.app/Contents/Helpers/tilr').read_bytes(), self.clients[arch])
        self.assertTrue(all(url.startswith(('https://github.com/tilr-dev/tilrd/', 'https://api.github.com/repos/tilr-dev/tilrd/',
                                            'https://raw.githubusercontent.com/tilr-dev/tilrd/v0.2.0/'))
                            for url in self.remote))

    def test_release_identity_can_follow_an_adjacent_rust_string(self):
        for arch in fetch_server.TARGETS:
            self.archive(arch, version='no-exec0.2.0-abcdef0')
        self.assertEqual(self.main(), 0)

    def test_other_release_number_is_not_a_substring_match(self):
        self.archive('arm64', version='10.2.0-abcdef0')
        with self.assertRaisesRegex(ValueError, 'release version/platform'):
            self.main()
        self.assertFalse((self.root / 'build').exists())

    def test_staging_on_another_filesystem_preserves_bytes_and_executable_mode(self):
        # rename(2) cannot move the verified file from system temp onto another volume.
        with patch.object(Path, 'rename', side_effect=OSError(errno.EXDEV, 'Cross-device link')):
            self.assertEqual(self.main(), 0)
        for arch in fetch_server.TARGETS:
            binary = self.root / f'build/server-releases/0.2.0-{arch}/tilrd'
            self.assertEqual(binary.read_bytes(), self.binaries[arch])
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            client = binary.with_name('tilr')
            self.assertEqual(client.read_bytes(), self.clients[arch])
            self.assertEqual(client.stat().st_mode & 0o777, 0o755)

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

    def test_invalid_signature_stops_acquisition_before_execution_or_install(self):
        with self.patches(), patch.object(fetch_server.subprocess, 'run',
                                         side_effect=subprocess.CalledProcessError(1, 'codesign')):
            with self.assertRaises(subprocess.CalledProcessError):
                fetch_server.main()
        self.assertFalse((self.root / 'build').exists())
        self.assertFalse(any(c[1:] == ['--version'] for c in self.commands))

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

    def test_missing_duplicate_or_mismatched_client_prevents_completion(self):
        for options in (dict(omit_client=True), dict(duplicate_client=True),
                        dict(client_version="0.2.0-1234567")):
            with self.subTest(options=options):
                self.archive('arm64', **options)
                with self.assertRaises(ValueError):
                    self.main()
                self.assertFalse((self.root / 'build').exists())

    def test_foreign_client_must_match_the_full_server_identity(self):
        self.archive('x86_64', client_version='0.2.0-1234567')
        with self.assertRaisesRegex(ValueError, 'Client and server upstream versions differ'):
            self.main()
        self.assertFalse((self.root / 'build').exists())

    def test_client_signature_failure_prevents_completed_output(self):
        def command(command, **kwargs):
            if command[0] == 'codesign' and Path(command[-1]).name.startswith('tilr-'):
                raise subprocess.CalledProcessError(1, command)
            return self.command_run(command, **kwargs)
        with self.patches(), patch.object(fetch_server.subprocess, 'run', side_effect=command):
            with self.assertRaises(subprocess.CalledProcessError):
                fetch_server.main()
        self.assertFalse((self.root / 'build').exists())

    def test_client_team_timestamp_architecture_and_version_are_verified(self):
        for fault in ('team', 'timestamp', 'arch', 'version'):
            with self.subTest(fault=fault):
                def run(command, **kwargs):
                    result = self.command_run(command, **kwargs)
                    if command[0] == 'codesign' and Path(command[-1]).name.startswith('tilr-'):
                        if fault == 'team':
                            result.stderr = self.signature.replace(fetch_server.TEAM, 'OTHER')
                        if fault == 'timestamp':
                            result.stderr = self.signature.replace('Timestamp=Oct 27, 2026\n', '')
                    return result
                def output(command, **kwargs):
                    if command[0] == 'lipo' and Path(command[-1]).name == 'tilr-arm64' and fault == 'arch':
                        return 'x86_64\n'
                    if command[0] != 'lipo' and Path(command[0]).name == 'tilr-arm64' and fault == 'version':
                        return 'tilr 0.2.0-1234567 (macos-aarch64)\n'
                    return self.output(command, **kwargs)
                with self.patches(), patch.object(fetch_server.subprocess, 'run', side_effect=run), \
                        patch.object(fetch_server.subprocess, 'check_output', side_effect=output):
                    with self.assertRaises(ValueError):
                        fetch_server.main()
                self.assertFalse((self.root / 'build').exists())

    def test_packaged_client_metadata_and_bytes_are_verified(self):
        self.main()
        app = self.root / 'arm64.app'
        import plistlib
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            TilrServerProtocolVersion=1)))
        with self.patches():
            bundle_server.bundle_server(app, 'arm64', 1, root=self.root)
            bundle_server.verify_server(app, 'arm64')
            (app / 'Contents/Helpers/tilr').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                bundle_server.verify_server(app, 'arm64')

    def test_cached_client_tampering_or_missing_file_is_rejected(self):
        self.main()
        path = self.root / 'build/server-releases/0.2.0-arm64/tilr'
        path.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Client changed after'):
            self.main()
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            self.main()

    def test_cached_tampering_and_legacy_compiled_receipt_are_rejected(self):
        self.main()
        path = self.root / 'build/server-releases/0.2.0-arm64'
        (path / 'tilrd').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'changed after'):
            self.main()
        receipt = json.loads((path / 'release.json').read_text())
        receipt.pop('upstream')
        (path / 'release.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'completed upstream'):
            self.main()


    def test_latest_stable_release_is_selected_for_bundling(self):
        self.assertEqual(self.main(), 0)
        selected = json.loads((self.root / 'build/server-releases/selected.json').read_text())
        self.assertEqual(selected, dict(version='0.2.0', protocolVersion=1))
        # A newer latest release does not change what an earlier acquisition selected.
        self.release('0.3.0')
        app = self.root / 'arm64.app'
        with self.patches():
            bundle_server.bundle_server(app, 'arm64', 1, root=self.root)
        self.assertEqual((app / 'Contents/Helpers/tilrd').read_bytes(), self.binaries['arm64'])
        self.assertFalse((app / 'Contents/Resources/server').exists())
        with self.patches(), self.assertRaisesRegex(ValueError, 'protocol does not match'):
            bundle_server.bundle_server(self.root / 'other.app', 'arm64', 2, root=self.root)

    def test_invalid_latest_release_or_protocol_stops_before_download(self):
        cases = (
            dict(tag='v0.3.0-rc.1'),
            dict(tag='nightly'),
            dict(protocol=None),
            dict(protocol='pub const PROTOCOL_VERSION: u32 = 0;\n'),
            dict(protocol='// no protocol\n'),
        )
        for case in cases:
            with self.subTest(case=case):
                self.release('0.2.0', **case)
                with self.assertRaises(ValueError):
                    self.main()
                self.assertFalse((self.root / 'build/server-releases').exists())
        del self.remote[fetch_server.LATEST_URL]
        with self.assertRaisesRegex(ValueError, 'No stable tilrd GitHub Release'):
            self.main()

    def test_latest_release_of_another_protocol_stops_acquisition(self):
        self.release('0.2.0', protocol='pub const PROTOCOL_VERSION: u32 = 2;\n')
        with self.assertRaisesRegex(ValueError, 'speaks protocol 2; this application supports protocol 1'):
            self.main()
        self.assertFalse((self.root / 'build/server-releases').exists())

    def test_latest_release_lookup_authenticates_without_logging_the_token(self):
        with patch.dict('os.environ', {'GH_TOKEN': 'secret-token'}):
            self.assertEqual(self.main(), 0)
        api = [headers for url, headers in self.requests if url == fetch_server.LATEST_URL]
        self.assertEqual(api, [['Accept: application/vnd.github+json', 'Authorization: Bearer secret-token\n']])
        self.assertFalse(any('secret-token' in str(arg) for command in self.commands for arg in command))
        self.assertTrue(all(not headers for url, headers in self.requests if url != fetch_server.LATEST_URL))
        with patch.dict('os.environ', {}, clear=True):
            self.requests.clear()
            self.main()
        self.assertEqual([h for url, h in self.requests if url == fetch_server.LATEST_URL], [['Accept: application/vnd.github+json']])

if __name__ == '__main__':
    unittest.main()
