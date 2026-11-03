#!/usr/bin/env python3
"""Build a separate test app, check native packages, optionally run the GUI probe.

Never replaces/restarts the user's app. --gui needs a logged-in WindowServer
session; the package/ABI tests work without one.
"""
import argparse
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT / 'native-plugins'


def delayed_handoff_site(site, stage):
    """Hold runtime publication until the probe reads it, after didFinish.

    The first read returns undefined and releases boot in a microtask. The old
    probe fails that read; an event-based waiter subscribes before boot resumes.
    This creates the ordering directly, without a clock delay.
    """
    target = stage / 'delayed-runtime'
    shutil.copytree(site, target)
    runtime = target / 'runtime.js'
    script = runtime.read_text()
    marker = 'window.tilr = {'
    if script.count(marker) != 1:
        raise ValueError('Expected one runtime publication in runtime.js')
    gate = """
window.__handoffBootGate = new Promise(release => {
  Object.defineProperty(window, 'tilr', {
    configurable: true,
    get() { release(); return undefined; },
    set(value) {
      Object.defineProperty(window, 'tilr', { value, writable: true, configurable: true });
      window.__handoffBootReleased = true;
    }
  });
});
"""
    # Install before module evaluation: the probe may read before boot reaches
    # the publication line. Keep that release rather than waiting for a second read.
    index = target / 'index.html'
    index.write_text('<script>' + gate + '</script>' + index.read_text())
    runtime.write_text(script.replace(marker, 'await window.__handoffBootGate;\n' + marker))
    return target


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gui', action='store_true')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--handoff', action='store_true', help='run the real-page layout handoff probe (requires --site)')
    parser.add_argument('--site', type=Path, help='composed runtime site for --handoff')
    parser.add_argument('--shell-control', action='store_true', help='run only the native shell Control GUI probe on a minimal page')
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    if args.handoff and not args.site:
        parser.error('--handoff requires --site')
    env = os.environ.copy()
    env.setdefault('CLANG_MODULE_CACHE_PATH', str(ROOT / '.build/module-cache'))
    env.setdefault('SWIFTPM_MODULECACHE_OVERRIDE', str(ROOT / '.build/module-cache'))
    swift = ['swift', 'build', '--build-system', 'native', '--package-path', ROOT, '--disable-sandbox', '--skip-update', '-c', args.configuration]
    if not args.skip_build:
        run(*swift, env=env)
        if not args.shell_control and not args.handoff:
            run('python3', REPO / 'scripts/plugin.py', 'build', '--configuration', args.configuration)
    binary = Path(run(*swift, '--show-bin-path', env=env, capture_output=True, text=True).stdout.strip()) / 'Tilr'
    packages = REPO / 'dist' / platform.machine()
    with tempfile.TemporaryDirectory(prefix='tilr-native-check-') as temp:
        stage = Path(temp)
        app = stage / 'Tilr.app'
        contents = app / 'Contents'
        for name in ['MacOS', 'Frameworks', 'Resources', 'PlugIns']:
            (contents / name).mkdir(parents=True)
        shutil.copy2(binary, contents / 'MacOS/Tilr')
        info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        info['CFBundleIdentifier'] += '.native-test'
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        framework = ROOT / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
        run('ditto', framework, contents / 'Frameworks/Sparkle.framework')
        for package in packages.glob('*.tilrplugin'):
            shutil.copytree(package, contents / 'PlugIns' / package.name)
        shutil.copy2(ROOT / 'placeholder.html', contents / 'Resources/placeholder.html')
        run('codesign', '--force', '--sign', '-', '--entitlements', ROOT / 'Tilr.entitlements', app)
        if not args.shell_control and not args.handoff:
            run('python3', REPO / 'scripts/test_plugins.py', '--app', app, '--packages', packages, '-v')
        if args.gui or args.shell_control or args.handoff:
            config = stage / 'config'
            config.mkdir()
            other = stage / 'other-app'
            other.mkdir()
            (other / 'index.html').write_text('<html><body>Other window app</body></html>')
            site = args.site.resolve() if args.handoff else other if args.shell_control else ROOT.parent / 'web/site'
            sites = [site, delayed_handoff_site(site, stage)] if args.handoff else [site]
            for site in sites:
                # Two configured apps exercise focus-or-create for a closed app as well as duplicates.
                (config / 'config.yml').write_text(
                    'window: { mode: window, activate_at_launch: false }\n'
                    'local_server: { enabled: false }\n'
                    f'apps:\n  - {{ name: default, site: "{site}" }}\n'
                    f'  - {{ name: other, site: "{other}" }}\n')
                # This exact test process exits itself after probing. No pid/name-based kill.
                run(contents / 'MacOS/Tilr', '--config', config, '--no-updates', '--probe-handoff' if args.handoff else '--probe-shell-control' if args.shell_control else '--probe',
                    timeout=120)
            if args.handoff:
                # The scheme handler rejects this missing file directly, without
                # any HTTP stack, network permission or connection timing involved.
                failed = subprocess.run(
                    [str(contents / 'MacOS/Tilr'), '--config', str(config), '--no-updates',
                     '--probe-handoff', '--url', 'tilr://default/handoff-probe-missing.html'],
                    capture_output=True, text=True, timeout=120)
                diagnostic = 'source: navigation failed:'
                if failed.returncode != 1 or 'probe-handoff: FAIL ' not in failed.stderr or diagnostic not in failed.stderr:
                    raise AssertionError(f'Expected explicit source navigation failure: {failed.stdout}\n{failed.stderr}')
                print('layout handoff: source navigation failure is explicit: ok')


if __name__ == '__main__':
    main()
