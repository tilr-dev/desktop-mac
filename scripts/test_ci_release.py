"""CI helper integration tests with deterministic curl and gh boundaries."""
import json
import hashlib
import plistlib
import os
import re
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
        # The selected tag is checked against checkout HEAD, never the push event SHA.
        self.env['GITHUB_SHA'] = 'b' * 40
        self.executable('git', "print('a' * 40)")
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
        (self.root / 'tag').write_text(json.dumps({'object': {'type': 'commit', 'sha': 'a' * 40}}))
        (self.root / 'release').write_text(json.dumps(dict(isPrerelease=True, isDraft=False,
                                                         body=self.env['NOTES'], assets=[])))
        self.executable('gh', '''import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
args = sys.argv[1:]
with (root / 'calls').open('a') as out:
    out.write(json.dumps(args) + '\\n')
if args[0] == 'api':
    print((root / 'tag').read_text())
elif args[:2] == ['release', 'view']:
    print((root / 'release').read_text())
elif args[:2] == ['release', 'upload']:
    assets = {pathlib.Path(p).name: pathlib.Path(p).read_text() for p in args if p.endswith('.dmg')}
    (root / 'uploaded').write_text(json.dumps(assets))
elif args[:2] == ['release', 'edit']:
    (root / 'edited').write_text(json.dumps(args))
else:
    sys.exit('unexpected gh mutation')
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
        return subprocess.run([sys.executable, '-c', self.bootstrap(), str(SCRIPT), *args],
                              env=self.env, capture_output=True, text=True)

    @staticmethod
    def bootstrap():
        # Keep real manifest/hash/bundle validation and orchestration; replace only
        # Apple binary checks, credential preflight and the final CDN subprocess.
        return f"""import json, os, pathlib, runpy, sys
sys.path.insert(0, {str(SCRIPT.parent)!r})
import fetch_server, release_all
fetch_server.check_binary = lambda *args: '0.2.1-abcdef0'
release_all.preflight = lambda *args, **kwargs: None
original = release_all.subprocess.run
def boundary(command, **kwargs):
    if len(command) > 1 and str(command[1]).endswith('/scripts/publish.py'):
        directory = pathlib.Path(command[2])
        root = pathlib.Path(os.environ['FIXTURE_ROOT'])
        with (root / 'cdn-calls').open('a') as out:
            out.write(json.dumps([directory.name, '--publish' in command]) + '\\n')
        if '--publish' in command:
            (directory / 'published.json').write_text(json.dumps(dict(download='https://cdn.tilr.dev/' + directory.name)))
        return
    return original(command, **kwargs)
release_all.subprocess.run = boundary
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
"""

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

    def assets(self, channel='beta', root=None, custom_name=False):
        root = root or self.root
        for arch in ('arm64', 'x86_64'):
            directory = root / f'0.3.0-13-{arch}'
            directory.mkdir(parents=True)
            name = f'custom-{arch}.dmg' if custom_name else f'Tilr-0.3.0-13-{arch}.dmg'
            dmg = directory / name
            dmg.write_text(f'signed notarized {arch}')
            prefix = 'beta/' if channel == 'beta' else ''
            meta = dict(version='0.3.0', build=13, arch=arch, preview=False,
                        dmg=name, sha256=hashlib.sha256(dmg.read_bytes()).hexdigest(),
                        feed=f'https://cdn.tilr.dev/mac/{prefix}{arch}/appcast.xml', public_key='public')
            (directory / 'release.json').write_text(json.dumps(meta))
            contents = directory / 'Tilr.app/Contents'
            contents.mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps(dict(
                CFBundleIdentifier='dev.tilr.mac', CFBundleVersion='13', CFBundleShortVersionString='0.3.0',
                SUPublicEDKey='public', TilrUpdateFeedSelection='preferences', TilrServerProtocolVersion=1,
                TilrBundledServerBuild=4, TilrBundledServerVersion='0.2.1')))
            helpers = contents / 'Helpers'
            helpers.mkdir()
            (helpers / 'tilrd').write_bytes(b'server')
            (helpers / 'tilr').write_bytes(b'client')
            server = contents / 'Resources/server'
            server.mkdir(parents=True)
            (server / 'app-managed.json').write_text(json.dumps(dict(
                version='0.2.1', build=4, arch=arch, protocolVersion=1, minAppBuild=1, maxAppBuild=None,
                serverVersion='0.2.1-abcdef0', sha256=hashlib.sha256(b'server').hexdigest())))
            (server / 'client.json').write_text(json.dumps(dict(
                version='0.2.1-abcdef0', sha256=hashlib.sha256(b'client').hexdigest())))

    def github(self, tag='v0.3.0-rc.2'):
        return self.run_helper('github', '--tag', tag, '--build', '13', '--root', str(self.root))

    def calls(self):
        return [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]

    def metadata(self, tag='v0.3.0-rc.2'):
        return self.run_helper('release', '--tag', tag, '--notes-file', str(self.root / 'notes'))

    def test_shared_candidate_metadata_build_and_artifact_publication(self):
        self.feed('arm64', [12], channel='beta')
        metadata = self.metadata()
        self.assertEqual(metadata.returncode, 0, metadata.stderr)
        self.assertEqual((self.root / 'output').read_text(), 'version=0.3.0\nchannel=beta\n')
        self.assertEqual((self.root / 'notes').read_text(), self.env['NOTES'])
        self.assert_build(13)
        self.assets()
        before_tag = (self.root / 'tag').read_text()
        before_release = (self.root / 'release').read_text()
        result = self.github()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(calls[0], ['api', 'repos/tilr-dev/tilr-mac/git/ref/tags/v0.3.0-rc.2'])
        upload = next(c for c in calls if c[:2] == ['release', 'upload'])
        self.assertEqual(upload[:5], ['release', 'upload', 'v0.3.0-rc.2', '--repo', self.env['GITHUB_REPOSITORY']])
        self.assertNotIn('--clobber', upload)
        self.assertEqual(json.loads((self.root / 'uploaded').read_text()),
                         {f'Tilr-0.3.0-13-{a}.dmg': f'signed notarized {a}' for a in ('arm64', 'x86_64')})
        self.assertIn('Tilr 0.3.0-rc.2 (13)', json.loads((self.root / 'edited').read_text()))
        self.assertEqual((self.root / 'tag').read_text(), before_tag)
        self.assertEqual((self.root / 'release').read_text(), before_release)
        self.assertFalse(any('create' in c or 'DELETE' in c or 'PATCH' in c for c in calls))

    def test_workflow_shell_passes_candidate_through_build_and_publication(self):
        self.workflow_shell('beta')

    def test_workflow_shell_builds_stable_tag_and_publishes_regular_release(self):
        self.workflow_shell('stable')

    def workflow_shell(self, channel):
        from test_release_workflow import WORKFLOW, jobs, steps, index
        workflow = jobs(WORKFLOW.read_text())
        tag = 'v0.3.0-rc.2' if channel == 'beta' else 'v0.3.0'
        state = json.loads((self.root / 'release').read_text())
        state['isPrerelease'] = channel == 'beta'
        (self.root / 'release').write_text(json.dumps(state))
        context = {'needs.release.outputs.tag': tag, 'github.token': 'fixture-token'}
        self.feed('x86_64', [12], channel='beta')
        # Actual workflow shell and helper commands; fake only packaging and CDN.
        self.executable('python3', """import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
if args[0] == 'scripts/ci_release.py':
    sys.exit(subprocess.call([sys.executable, '-c', os.environ['CI_BOOTSTRAP'], os.environ['CI_SCRIPT'], *args[1:]]))
assert args[0] == 'scripts/release_all.py'
assert '--publish-only' not in args and '--publish' not in args
version, build = args[args.index('--version') + 1], args[args.index('--build') + 1]
assert version == '0.3.0' and build == '13'
assert args[args.index('--channel') + 1] == os.environ['EXPECTED_CHANNEL']
""")
        def run_step(job, marker):
            step = steps(workflow[job])[index(workflow[job], marker)]
            env = dict(self.env, RUNNER_TEMP=str(self.root), CI_SCRIPT=str(SCRIPT),
                       CI_BOOTSTRAP=self.bootstrap(), EXPECTED_CHANNEL=channel,
                       TILR_UPDATE_PUBLIC_KEY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
                       GITHUB_STEP_SUMMARY=str(self.root / 'summary'))
            for key, expression in re.findall(r'^          ([A-Z_]+): \$\{\{ (.+?) \}\}', step, re.M):
                env[key] = context[expression]
            script = step.split('run: ', 1)[1]
            if script.startswith('|\n'):
                script = '\n'.join(line[10:] for line in script[2:].splitlines())
            result = subprocess.run(['bash', '-eo', 'pipefail', '-c', script], cwd=self.root,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        run_step('app', 'ci_release.py release')
        metadata = dict(line.split('=') for line in (self.root / 'output').read_text().splitlines())
        self.assertEqual(metadata, dict(version='0.3.0', channel=channel))
        context.update({f'steps.metadata.outputs.{key}': value for key, value in metadata.items()})
        run_step('app', 'ci_release.py build')
        build = (self.root / 'output').read_text().splitlines()[-1].split('=')[1]
        context.update({'steps.number.outputs.build': build, 'needs.app.outputs.build': build,
                        'needs.app.outputs.version': '0.3.0', 'needs.app.outputs.channel': channel,
                        'secrets.APPLE_SIGN_IDENTITY': 'fixture',
                        'secrets.AWS_ACCESS_KEY_ID': 'fixture', 'secrets.AWS_SECRET_ACCESS_KEY': 'fixture'})
        run_step('app', 'name: Sign, notarize and package')
        releases = self.root / 'build/releases'
        self.assets(channel, releases)
        # Match the configured key, preserving real receipt/bundle validation.
        for directory in releases.iterdir():
            meta = json.loads((directory / 'release.json').read_text())
            meta['public_key'] = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
            (directory / 'release.json').write_text(json.dumps(meta))
            info = directory / 'Tilr.app/Contents/Info.plist'
            data = plistlib.loads(info.read_bytes())
            data['SUPublicEDKey'] = meta['public_key']
            info.write_bytes(plistlib.dumps(data))
        run_step('publish', 'ci_release.py release')
        run_step('publish', 'name: Publish the app')
        run_step('publish', 'ci_release.py github')
        self.assertEqual(json.loads((self.root / 'uploaded').read_text()),
                         {f'Tilr-0.3.0-13-{a}.dmg': f'signed notarized {a}' for a in ('arm64', 'x86_64')})
        events = [json.loads(line) for line in (self.root / 'cdn-calls').read_text().splitlines()]
        self.assertEqual(events, [[f'0.3.0-13-{a}', publish] for publish in (False, True)
                                  for a in ('arm64', 'x86_64')])
        self.assertEqual((self.root / 'notes.txt').read_text(), self.env['NOTES'])
        title = f'Tilr {tag[1:]} (13)'
        self.assertIn(title, json.loads((self.root / 'edited').read_text()))
        self.assertFalse(any('--prerelease' in call or 'create' in call for call in self.calls()))
        self.assertEqual(json.loads((self.root / 'release').read_text()), state)

    def test_invalid_tag_never_calls_github(self):
        for tag in ('v0.3', 'v0.3.0-rc.0', 'v0.3.0-rc.01', 'v0.3.0-rc.x', '', '$(bad)'):
            with self.subTest(tag=tag):
                result = self.metadata(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'calls').exists())
                self.assertFalse((self.root / 'output').exists())

    def test_wrong_commit_or_annotated_tag_stops_before_publication(self):
        for target in ({'type': 'commit', 'sha': 'b' * 40}, {'type': 'tag', 'sha': 'a' * 40}):
            (self.root / 'tag').write_text(json.dumps({'object': target}))
            result = self.metadata()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('does not point to checked-out commit', result.stderr)
            self.assertFalse((self.root / 'output').exists())
            self.assertFalse((self.root / 'notes').exists())

    def test_existing_assets_stable_release_and_draft_are_preserved(self):
        self.assets()
        for patch in (dict(assets=[{'name': 'existing.dmg'}]), dict(isPrerelease=False), dict(isDraft=True)):
            state = dict(isPrerelease=True, isDraft=False, body='original', assets=[])
            state.update(patch)
            (self.root / 'release').write_text(json.dumps(state))
            for action in (self.metadata, self.github):
                result = action()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'uploaded').exists())
                self.assertFalse((self.root / 'edited').exists())
                self.assertEqual(json.loads((self.root / 'release').read_text()), state)

    def publish(self, tag='v0.3.0'):
        return self.run_helper('publish', '--tag', tag, '--build', '13', '--root', str(self.root),
                               '--notes-file', str(self.root / 'notes'))

    def stable(self):
        state = dict(isPrerelease=False, isDraft=False, body=self.env['NOTES'], assets=[])
        (self.root / 'release').write_text(json.dumps(state))
        return state

    def assert_no_mutation(self):
        for name in ('cdn-calls', 'uploaded', 'edited'):
            self.assertFalse((self.root / name).exists(), name)

    def test_published_stable_stops_before_cdn_or_release_changes(self):
        state = self.stable()
        state['assets'] = [dict(name='existing.dmg')]
        (self.root / 'release').write_text(json.dumps(state))
        for action in (self.metadata, self.publish, self.github):
            result = action('v0.3.0')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('already has assets', result.stderr)
            self.assert_no_mutation()
        self.assertEqual(json.loads((self.root / 'release').read_text()), state)

    def test_stale_stable_build_stops_before_cdn_or_release_changes(self):
        self.stable()
        self.assets('stable')
        for arch in ('arm64', 'x86_64'):
            self.feed(arch, [13, 16])
            result = self.publish()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('must be greater than published build', result.stderr)
            self.assert_no_mutation()

    def test_manifest_sha256_failure_in_second_arch_stops_all_mutations(self):
        self.stable()
        self.assets('stable')
        (self.root / '0.3.0-13-x86_64/Tilr-0.3.0-13-x86_64.dmg').write_text('tampered')
        for action in (self.publish, self.github):
            result = action('v0.3.0')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('DMG changed since successful release completion', result.stderr)
            self.assert_no_mutation()

    def test_github_uses_validated_manifest_dmg_paths(self):
        self.stable()
        self.assets('stable', custom_name=True)
        result = self.github('v0.3.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(json.loads((self.root / 'uploaded').read_text())),
                         {'custom-arm64.dmg', 'custom-x86_64.dmg'})

    def test_wrong_receipt_channel_stops_before_mutation(self):
        self.stable()
        self.assets('beta')
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('metadata does not match', result.stderr)
        self.assert_no_mutation()

    def test_missing_dmg_does_not_mutate_shared_release(self):
        result = self.github()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('release.json', result.stderr)
        self.assertFalse((self.root / 'uploaded').exists())
        self.assertFalse((self.root / 'edited').exists())


if __name__ == '__main__':
    unittest.main()
