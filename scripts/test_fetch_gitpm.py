import hashlib
import io
import shutil
from contextlib import ExitStack
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import fetch_gitpm

TAG = 'v0.6.0-rc.1'
COMMIT = 'a' * 40
LIBRARY = 'GitpmFFI.xcframework/macos-arm64_x86_64/libgitpm_ffi.a'


class FetchGitpmTests(unittest.TestCase):
    """Downloads, git ls-remote and lipo are stubs: no network, no gitpm sources, no Rust."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.remote = {}
        self.requests = []
        self.tags = {TAG: COMMIT}
        self.slices = {'arm64', 'x86_64'}
        self.swift = b'// generated API 1\n'
        self.archive()

    def archive(self, extra=(), omit=(), symlink=None):
        url = fetch_gitpm.archive_url(TAG)
        top = Path(url).name.removesuffix('.tar.gz')
        files = {
            'GitpmFFI.xcframework/Info.plist': b'<plist/>',
            LIBRARY: b'static library',
            'GitpmFFI.xcframework/macos-arm64_x86_64/Headers/GitpmFFI.h': b'// header',
            'swift/Gitpm.swift': self.swift,
            'README.md': b'readme',
        }
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as tar:
            for name, content in [*((n, c) for n, c in files.items() if n not in omit), *extra]:
                entry = tarfile.TarInfo(name if name.startswith(('/', '..', 'other')) else f'{top}/{name}')
                entry.size = len(content)
                tar.addfile(entry, io.BytesIO(content))
            if symlink:
                entry = tarfile.TarInfo(f'{top}/{symlink}')
                entry.type = tarfile.SYMTYPE
                entry.linkname = '/tmp/outside'
                tar.addfile(entry)
        self.remote[url] = data.getvalue()
        self.sha256 = hashlib.sha256(data.getvalue()).hexdigest()
        self.remote[url + '.sha256'] = f'{self.sha256}  {Path(url).name}\n'.encode()
        self.pin()

    def pin(self, line=None):
        (self.root / 'gitpm.pin').write_text(f'# comment\n{line or f"{TAG} {COMMIT} {self.sha256}"}\n')

    def fetch(self, url, path, headers=()):
        self.requests.append(url)
        if url not in self.remote:
            return False
        path.write_bytes(self.remote[url])
        return True

    def command(self, command, **kwargs):
        if command[:2] == ['git', 'ls-remote']:
            tag = command[3].removeprefix('refs/tags/')
            commit = self.tags.get(tag)
            out = f'{"b" * 40}\trefs/tags/{tag}\n{commit}\trefs/tags/{tag}^{{}}\n' if commit else ''
            return subprocess.CompletedProcess(command, 0, stdout=out)
        if command[0] == 'lipo':
            self.assertTrue(command[1].endswith('libgitpm_ffi.a'))
            return subprocess.CompletedProcess(command, 0 if command[3] in self.slices else 1)
        raise AssertionError(command)

    def main(self):
        with ExitStack() as stack:
            stack.enter_context(patch.object(fetch_gitpm, 'ROOT', self.root))
            stack.enter_context(patch.object(fetch_gitpm, 'fetch', self.fetch))
            stack.enter_context(patch.object(fetch_gitpm.subprocess, 'run', self.command))
            stack.enter_context(patch('sys.argv', ['fetch_gitpm.py']))
            return fetch_gitpm.main()

    def installed_files(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file() and p.name != 'gitpm.pin'}

    def test_installs_pinned_release_where_build_gitpm_looks(self):
        self.assertEqual(self.main(), 0)
        self.assertEqual((self.root / 'Vendor' / LIBRARY).read_bytes(), b'static library')
        self.assertEqual((self.root / 'Sources/Gitpm/Generated/Gitpm.swift').read_bytes(), self.swift)
        self.assertEqual((self.root / 'Vendor/.gitpm-built').read_text(), f'release {TAG} {self.sha256}\n')
        self.assertFalse((self.root / 'Vendor/README.md').exists())

    def test_installed_release_is_reused_without_download(self):
        self.main()
        self.requests.clear()
        self.assertEqual(self.main(), 0)
        self.assertEqual(self.requests, [])

    def test_missing_file_after_install_downloads_again(self):
        self.main()
        (self.root / 'Sources/Gitpm/Generated/Gitpm.swift').unlink()
        self.requests.clear()
        self.assertEqual(self.main(), 0)
        self.assertEqual(len(self.requests), 2)
        self.assertTrue((self.root / 'Sources/Gitpm/Generated/Gitpm.swift').is_file())

    def test_new_pin_replaces_previous_release(self):
        self.main()
        (self.root / 'Vendor/GitpmFFI.xcframework/stale').write_text('old')
        self.swift = b'// generated API 2\n'
        self.archive()
        self.assertEqual(self.main(), 0)
        self.assertFalse((self.root / 'Vendor/GitpmFFI.xcframework/stale').exists())
        self.assertEqual((self.root / 'Sources/Gitpm/Generated/Gitpm.swift').read_bytes(), self.swift)

    def test_malformed_pin_is_rejected_before_download(self):
        for line in ('main ' + 'b' * 40, f'0.6.0 {COMMIT} {"c" * 64}', f'{TAG} abc {"c" * 64}', f'{TAG} {COMMIT} xyz'):
            with self.subTest(line=line):
                self.pin(line)
                with self.assertRaisesRegex(ValueError, 'must hold one line'):
                    self.main()
        self.assertEqual(self.requests, [])

    def test_swift_copy_failure_preserves_previous_installation(self):
        self.main()
        before = self.installed_files()
        self.swift = b'// generated API 2\n'
        self.archive()
        copyfile = shutil.copyfile

        def fail_swift(src, dst, **kwargs):
            if Path(src).name == 'Gitpm.swift':
                raise OSError('Swift copy failed')
            return copyfile(src, dst, **kwargs)

        with patch.object(fetch_gitpm.shutil, 'copyfile', fail_swift):
            with self.assertRaisesRegex(OSError, 'Swift copy failed'):
                self.main()
        self.assertEqual(self.installed_files(), before)

    def test_replacement_failure_rolls_back_previous_installation(self):
        self.main()
        before = self.installed_files()
        self.swift = b'// generated API 2\n'
        self.archive()
        replace = Path.replace
        swift = self.root / 'Sources/Gitpm/Generated/Gitpm.swift'

        def fail_replace(path, target):
            if Path(target) == swift and path.name == 'new-swift':
                raise OSError('Swift replacement failed')
            return replace(path, target)

        with patch.object(Path, 'replace', fail_replace):
            with self.assertRaisesRegex(OSError, 'Swift replacement failed'):
                self.main()
        self.assertEqual(self.installed_files(), before)

    def assert_rejected(self, pattern):
        """A rejected release leaves the previously installed plugin manager unchanged."""
        before = self.installed_files()
        with self.assertRaisesRegex(ValueError, pattern):
            self.main()
        self.assertEqual(self.installed_files(), before)

    def test_missing_asset(self):
        self.remote.pop(fetch_gitpm.archive_url(TAG) + '.sha256')
        self.assert_rejected('Missing gitpm release asset')

    def test_published_checksum_mismatch(self):
        self.remote[fetch_gitpm.archive_url(TAG) + '.sha256'] = f'{"0" * 64}  x.tar.gz\n'.encode()
        self.assert_rejected('published checksum')

    def test_pinned_checksum_mismatch(self):
        self.pin(f'{TAG} {COMMIT} {"0" * 64}')
        self.assert_rejected('differs from gitpm.pin')

    def test_tag_pointing_elsewhere_or_absent(self):
        self.tags[TAG] = 'c' * 40
        self.assert_rejected('does not point to the pinned commit')
        self.tags.clear()
        self.assert_rejected(f'no tag {TAG}')

    def test_unsafe_entries(self):
        for kwargs in (dict(symlink='swift/link'), dict(extra=[('../escape', b'x')]),
                       dict(extra=[('/abs', b'x')]), dict(extra=[('other-top/file', b'x')])):
            with self.subTest(**{k: str(v) for k, v in kwargs.items()}):
                self.archive(**kwargs)
                self.assert_rejected('Unsafe gitpm archive entry')

    def test_incomplete_archive(self):
        for missing in ('swift/Gitpm.swift', LIBRARY, 'GitpmFFI.xcframework/Info.plist'):
            with self.subTest(missing=missing):
                self.archive(omit=(missing,))
                self.assert_rejected('must contain GitpmFFI.xcframework')

    def test_missing_slice_after_previous_install(self):
        self.main()
        self.swift = b'// generated API 2\n'
        self.archive()
        self.slices = {'arm64'}
        self.assert_rejected('no x86_64 slice')
        self.assertEqual((self.root / 'Sources/Gitpm/Generated/Gitpm.swift').read_bytes(), b'// generated API 1\n')


if __name__ == '__main__':
    unittest.main()
