"""CI helper integration tests with deterministic curl and gh boundaries."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('ci_release.py')


class CIReleaseIntegration(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                        FIXTURE_ROOT=str(self.root), GITHUB_OUTPUT=str(self.root / 'output'),
                        GITHUB_REPOSITORY='tilr-dev/tilr-mac', GITHUB_SHA='a' * 40,
                        NOTES='First line\nSecond line with `code` and $(literal)\n')
        self.feeds = {}
        for channel in ('stable', 'beta'):
            for arch in ('arm64', 'x86_64'):
                self.feed(arch, channel=channel, status='404')
        self.executable('curl', '''import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
args = sys.argv[1:]
entry = json.loads((root / 'feeds').read_text())[args[-1]]
if entry.get('exit'):
    sys.exit(entry['exit'])
pathlib.Path(args[args.index('-o') + 1]).write_text(entry.get('body', ''))
print(entry.get('status', '200'), end='')
''')
        self.executable('gh', '''import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
args = sys.argv[1:]
with (root / 'calls').open('a') as out:
    out.write(json.dumps(args) + '\\n')
if args[0] == 'api':
    if (root / 'tag').exists():
        print('Reference already exists (HTTP 422)', file=sys.stderr)
        sys.exit(1)
    (root / 'tag').write_text(json.dumps(args))
else:
    assets = {pathlib.Path(p).name: pathlib.Path(p).read_text() for p in args if p.endswith('.dmg')}
    notes = pathlib.Path(args[args.index('--notes-file') + 1]).read_text()
    (root / 'release').write_text(json.dumps(dict(args=args, assets=assets, notes=notes)))
''')

    def executable(self, name, source):
        path = self.root / name
        path.write_text(f'#!{sys.executable}\n' + source)
        path.chmod(0o755)

    def feed(self, arch, builds=(), channel='stable', status='200', raw=None, exit=None):
        prefix = 'beta/' if channel == 'beta' else ''
        body = raw if raw is not None else ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' +
            ''.join(f'<item><enclosure sparkle:version="{b}" /></item>' for b in builds) + '</channel></rss>')
        self.feeds[f'https://cdn.tilr.dev/mac/{prefix}{arch}/appcast.xml'] = dict(body=body, status=status, exit=exit)
        (self.root / 'feeds').write_text(json.dumps(self.feeds))

    def run_helper(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env, capture_output=True, text=True)

    def assert_build(self, expected, requested=''):
        (self.root / 'output').unlink(missing_ok=True)
        result = self.run_helper('build', '--build', requested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'output').read_text(), f'build={expected}\n')
        self.assertIn(f'App build: {expected}', result.stdout)

    def test_auto_build_uses_history_across_both_channels_and_architectures(self):
        for maximum_channel in ('stable', 'beta'):
            for maximum_arch in ('arm64', 'x86_64'):
                with self.subTest(channel=maximum_channel, arch=maximum_arch):
                    for channel in ('stable', 'beta'):
                        for arch in ('arm64', 'x86_64'):
                            self.feed(arch, [3, 12, 1] if (channel, arch) ==
                                      (maximum_channel, maximum_arch) else [8, 2], channel)
                    self.assert_build(13)

    def test_missing_and_empty_feeds(self):
        for status in ('200', '404'):
            self.feed('arm64', status=status)
            self.feed('x86_64', status='404')
            self.assert_build(1)
        self.feed('x86_64', [6])
        self.assert_build(7)

    def test_explicit_build_must_exceed_maximum(self):
        self.feed('arm64', [7])
        self.feed('x86_64', [9])
        self.feed('arm64', [15], 'beta')
        for value in ('7', '9', '14', '15', '0', '-1', 'oops', '1.5'):
            with self.subTest(build=value):
                result = self.run_helper('build', '--build', value)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'output').exists())
        self.assert_build(20, requested='20')

    def test_feed_errors_never_allocate_number_even_with_explicit_build(self):
        self.feed('arm64', [4])
        cases = [dict(status='403'), dict(status='500'), dict(exit=28),
                 dict(raw='not XML'), dict(raw='<rss/>'),
                 dict(raw='<rss><channel><item/></channel></rss>'), dict(builds=['oops'])]
        for case in cases:
            for requested in ('', '20'):
                with self.subTest(case=case, requested=requested):
                    self.feed('x86_64', **case)
                    result = self.run_helper('build', '--build', requested)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((self.root / 'output').exists())

    def assets(self):
        for arch in ('arm64', 'x86_64'):
            directory = self.root / f'0.3.0-13-{arch}'
            directory.mkdir()
            (directory / f'Tilr-0.3.0-13-{arch}.dmg').write_text(f'signed notarized {arch}')

    def github(self, rc='2', version='0.3.0'):
        return self.run_helper('github', '--version', version, '--build', '13', '--rc', rc, '--root', str(self.root))

    def test_github_uses_build_commit_notes_and_original_dmgs(self):
        self.assets()
        result = self.github()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        self.assertEqual(calls[0], ['api', '--method', 'POST', 'repos/tilr-dev/tilr-mac/git/refs',
                                  '-f', 'ref=refs/tags/v0.3.0-rc.2', '-f', 'sha=' + 'a' * 40])
        release = json.loads((self.root / 'release').read_text())
        self.assertEqual(release['args'][:4], ['release', 'create', 'v0.3.0-rc.2', '--repo'])
        self.assertEqual(release['args'][4], self.env['GITHUB_REPOSITORY'])
        self.assertIn('--verify-tag', release['args'])
        self.assertIn('--prerelease', release['args'])
        self.assertIn('Tilr 0.3.0-rc.2 (13)', release['args'])
        self.assertEqual(release['notes'], self.env['NOTES'])
        self.assertEqual(release['assets'], {f'Tilr-0.3.0-13-{a}.dmg': f'signed notarized {a}'
                                            for a in ('arm64', 'x86_64')})
        self.assertEqual(len(calls), 2)

    def test_existing_tag_preserves_tag_and_release(self):
        self.assets()
        (self.root / 'tag').write_text('original commit')
        (self.root / 'release').write_text('original release')
        result = self.github()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exist', result.stderr)
        self.assertEqual((self.root / 'tag').read_text(), 'original commit')
        self.assertEqual((self.root / 'release').read_text(), 'original release')
        self.assertEqual(len((self.root / 'calls').read_text().splitlines()), 1)

    def test_invalid_rc_or_marketing_version_does_not_call_github(self):
        self.assets()
        for rc in ('0', '-1', '1.5', '01', 'abc', ''):
            with self.subTest(rc=rc):
                result = self.github(rc=rc)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('RC number must be a positive integer', result.stderr)
                self.assertFalse((self.root / 'calls').exists())
        result = self.github(version='0.3.0-rc.2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid release version', result.stderr)
        self.assertFalse((self.root / 'calls').exists())

    def test_missing_dmg_does_not_create_tag(self):
        result = self.github()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing release DMG', result.stderr)
        self.assertFalse((self.root / 'calls').exists())


if __name__ == '__main__':
    unittest.main()
