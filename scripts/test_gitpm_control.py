#!/usr/bin/env python3
"""Exercise the embedded gitpm API through an isolated Tilr Control Unix socket.

Stages and signs a separate app. Requires a logged-in WindowServer session;
the user's app, configuration, and plugin workspace are never used.
"""
import argparse
import errno
import json
import os
from pathlib import Path
import plistlib
import pty
import selectors
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
PACKAGE_ID = '7e5d0000-0000-4000-8000-000000000808'
MISSING_ID = '7e5d0000-0000-4000-8000-000000000809'


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def stage_app(stage, binary):
    app = stage / 'Tilr.app'
    contents = app / 'Contents'
    for name in ['MacOS', 'Frameworks', 'Resources', 'PlugIns']:
        (contents / name).mkdir(parents=True)
    shutil.copy2(binary, contents / 'MacOS/Tilr')
    info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
    info['CFBundleIdentifier'] += '.gitpm-control-test'
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    framework = ROOT / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    run('ditto', framework, contents / 'Frameworks/Sparkle.framework')
    shutil.copy2(ROOT / 'placeholder.html', contents / 'Resources/placeholder.html')
    run('codesign', '--force', '--sign', '-', '--entitlements', ROOT / 'Tilr.entitlements', app)
    return contents / 'MacOS/Tilr'


class App:
    def __init__(self, binary, config, control, git_path=None):
        self.control = control
        self.request_id = 0
        self.log = b''
        self.master, slave = pty.openpty()
        try:
            # A terminal keeps Swift's readiness print line-buffered. Readiness is
            # NWListener.ready, not the socket file's creation or a timed retry.
            self.process = subprocess.Popen(
                [str(binary), '--config', str(config), '--no-updates'],
                stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                env={**os.environ, **({} if git_path is None else {'PATH': git_path}), 'GIT_AUTHOR_NAME': 'Tilr Control test',
                     'GIT_AUTHOR_EMAIL': 'control@example.invalid',
                     'GIT_COMMITTER_NAME': 'Tilr Control test',
                     'GIT_COMMITTER_EMAIL': 'control@example.invalid',
                     'GIT_CONFIG_COUNT': '2', 'GIT_CONFIG_KEY_0': 'commit.gpgsign',
                     'GIT_CONFIG_VALUE_0': 'false', 'GIT_CONFIG_KEY_1': 'core.hooksPath',
                     'GIT_CONFIG_VALUE_1': '/dev/null'})
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)

    def __enter__(self):
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(self.master, selectors.EVENT_READ)
                deadline = time.monotonic() + 30
                pending = b''
                ready = f'control: {self.control}'.encode()
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise AssertionError('Tilr did not announce Control readiness')
                    try:
                        chunk = os.read(self.master, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        chunk = b''
                    if not chunk:
                        raise AssertionError('Tilr exited before Control was ready')
                    self.log += chunk
                    pending += chunk
                    lines = pending.split(b'\n')
                    pending = lines.pop()
                    if any(line.rstrip(b'\r') == ready for line in lines):
                        return self
        except BaseException as error:
            self.__exit__(type(error), error, error.__traceback__)
            raise

    def __exit__(self, kind, value, traceback):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        os.close(self.master)
        if kind is not None:
            print(self.log.decode(errors='replace'))

    def request(self, command, args=None, **extra):
        self.request_id += 1
        request = {'id': self.request_id, 'cmd': 'gitpm', 'command': command,
                   'args': {} if args is None else args, **extra}
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(10)
            connection.connect(str(self.control))
            connection.sendall(json.dumps(request).encode() + b'\n')
            with connection.makefile('rb') as stream:
                line = stream.readline(1024 * 1024)
        assert line.endswith(b'\n'), f'incomplete Control reply: {line!r}'
        reply = json.loads(line)
        assert reply.get('id') == self.request_id, reply
        return reply

    def success(self, command, args=None):
        reply = self.request(command, args)
        assert reply.get('ok') is True and 'result' in reply, reply
        return reply['result']

    def failure(self, command, args=None, code=None, **extra):
        reply = self.request(command, args, **extra)
        assert reply.get('ok') is False, reply
        error = reply.get('error', {})
        assert isinstance(error.get('code'), str) and error['code'], reply
        assert error.get('kind') == error['code'], reply
        assert isinstance(error.get('message'), str) and error['message'], reply
        if code is not None:
            assert error['code'] == code, reply
        return error


def package_state(app, enabled):
    packages = app.success('list')
    assert isinstance(packages, list) and len(packages) == 1, packages
    package = packages[0]
    assert package['id'] == PACKAGE_ID, package
    assert package['enabled'] is enabled, package


def fixture(stage):
    source = stage / 'plugin'
    (source / 'dist').mkdir(parents=True)
    (source / 'plugin.json').write_text(json.dumps({
        'id': PACKAGE_ID, 'name': 'control-fixture', 'version': '0.1.0',
        'dependencies': {}}))
    (source / 'dist/index.js').write_text('export const controlFixture = true;\n')
    git = ['git', '-C', source, '-c', 'user.name=Tilr Control test',
           '-c', 'user.email=control@example.invalid', '-c', 'commit.gpgsign=false',
           '-c', 'tag.gpgsign=false', '-c', 'core.hooksPath=/dev/null']
    for args in [('init', '-q', '-b', 'main'), ('add', '--all'),
                 ('commit', '-q', '-m', 'Create Control fixture'), ('tag', 'v0.1.0')]:
        run(*git, *args, env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'})
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    env = os.environ.copy()
    env.setdefault('CLANG_MODULE_CACHE_PATH', str(ROOT / '.build/module-cache'))
    env.setdefault('SWIFTPM_MODULECACHE_OVERRIDE', str(ROOT / '.build/module-cache'))
    swift = ['swift', 'build', '--build-system', 'native', '--package-path', ROOT,
             '--disable-sandbox', '--skip-update', '-c', args.configuration]
    if not args.skip_build:
        run(*swift, env=env)
    binary = Path(run(*swift, '--show-bin-path', env=env,
                      capture_output=True, text=True).stdout.strip()) / 'Tilr'
    # /tmp keeps sockaddr_un.sun_path below macOS's length limit even when the
    # user's TMPDIR has a long per-user prefix.
    with tempfile.TemporaryDirectory(prefix='tilr-gitpm-', dir='/tmp') as temp:
        stage = Path(temp)
        executable = stage_app(stage, binary)
        source = fixture(stage)
        config = stage / 'config'
        config.mkdir()
        page = stage / 'page'
        page.mkdir()
        (page / 'index.html').write_text('<html><body>Control fixture</body></html>')
        catalog = stage / 'catalog'
        catalog.mkdir()
        (catalog / 'catalog.json').write_text('{"schema": 1, "directories": {}}\n')
        workspace = stage / 'workspace'
        control = stage / 'control.sock'
        override = stage / 'forbidden-workspace'
        (config / 'config.yml').write_text(
            'window: { mode: window, activate_at_launch: false }\n'
            'local_server: { enabled: false }\n'
            f'control: {{ socket: {json.dumps(str(control))} }}\n'
            f'plugin_manager: {{ workspace: {json.dumps(str(workspace))}, '
            f'catalog: {json.dumps(str(catalog))} }}\n'
            f'apps:\n  - {{ name: default, site: {json.dumps(str(page))} }}\n')
        # Deterministically deny Git lookup and require the app's preflight guidance,
        # rather than entering a library Git subprocess (or Apple's installation stub).
        with App(executable, config, control, git_path='') as app:
            for command, arguments in [
                    ('syncDistPlan', {}),
                    ('syncDist', {}),
                    ('enable', {'id': PACKAGE_ID}),
                    ('disable', {'id': PACKAGE_ID}),
                    ('forget', {'id': PACKAGE_ID}),
                    ('replace', {'original': PACKAGE_ID, 'replacement': MISSING_ID}),
                    ('link', {'package': str(source)}),
                    ('replaceResolve', {'original': PACKAGE_ID, 'replacement': MISSING_ID}),
                    ('repositoryPackages', {'directory': str(source)}),
                    ('editRepositoryDependency', {'directory': str(source), 'package': PACKAGE_ID,
                                                   'edit': {'type': 'remove', 'dependency': MISSING_ID}})]:
                error = app.failure(command, arguments, code='git')
                assert 'xcode-select --install' in error['message'], error
            assert not workspace.exists(), 'Git preflight created a workspace'
        with App(executable, config, control) as app:
            status = app.request('', cmd='plugin-manager')
            assert status['ok'] and status['plugins'] == [] and status['open'] is False, status
            assert not workspace.exists(), 'status created the plugin workspace'
            assert app.success('readState')['resolved'] == []
            assert not workspace.exists(), 'readState created the plugin workspace'
            author = stage / 'author-repo'
            initialized = app.success('init', {'directory': str(author), 'name': 'source-author'})
            assert initialized['version'] == '0.1.0', initialized
            packages = app.success('repositoryPackages', {'directory': str(author)})
            assert any(p['id'] == initialized['id'] for p in packages), packages
            committed = app.success('commit', {'directory': str(author), 'version': '0.2.0'})
            assert committed['version'] == '0.2.0', committed
            assert app.success('setRemote', {'directory': str(author), 'url': str(source)}) is None
            assert app.success('list') == []
            assert app.success('root') == str(workspace)
            overview = app.success('browseCatalog')
            assert overview['location'] == str(catalog) and not overview['truncated'], overview
            assert overview['items'] == [{'type': 'empty', 'depth': 1}], overview
            assert app.success('catalogLinks')['directories'] == {}
            report = app.success('check')
            assert isinstance(report, dict) and report.get('rows') == [], report
            app.failure('not-a-command', code='invalid_argument')
            app.failure('link', code='invalid_argument')
            app.failure('enable', {'id': 42}, code='invalid_argument')
            app.failure('list', [], code='invalid_argument')
            app.failure('list', {'root': str(override)}, code='invalid_argument')
            app.failure('list', code='invalid_argument', root=str(override))
            app.failure('enable', {'id': MISSING_ID})
            assert not override.exists(), 'Control accepted a workspace override'
            registered = app.success('catalogRegister', {'source': str(source), 'reference': 'v0.1.0'})
            assert registered['release']['id'] == PACKAGE_ID, registered
            sources = stage / 'sources.txt'
            sources.write_text(str(source) + '\n')
            updated = app.success('catalogUpdate', {'sourcesFile': str(sources)})
            assert isinstance(updated, dict), updated
            release = app.success('catalogRelease', {'id': PACKAGE_ID, 'version': '0.1.0'})
            assert release['version'] == '0.1.0', release
            linked = app.success('link', {'package': str(source)})
            assert linked['id'] == PACKAGE_ID, linked
            package_state(app, True)
            packages = app.success('repositoryPackages', {'directory': str(source)})
            assert any(p['id'] == PACKAGE_ID and p['installed'] for p in packages), packages
            app.success('disable', {'id': PACKAGE_ID})
            package_state(app, False)
        # A new app process must see the stored disabled state, then persist enable.
        with App(executable, config, control) as app:
            package_state(app, False)
            app.success('enable', {'id': PACKAGE_ID})
            package_state(app, True)
        with App(executable, config, control) as app:
            package_state(app, True)
        print('gitpm Control: all socket integration checks passed')


if __name__ == '__main__':
    main()
