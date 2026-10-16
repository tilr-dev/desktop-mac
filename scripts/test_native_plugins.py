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


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gui', action='store_true')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    env = os.environ.copy()
    env.setdefault('CLANG_MODULE_CACHE_PATH', str(ROOT / '.build/module-cache'))
    env.setdefault('SWIFTPM_MODULECACHE_OVERRIDE', str(ROOT / '.build/module-cache'))
    swift = ['swift', 'build', '--build-system', 'native', '--package-path', ROOT, '--disable-sandbox', '--skip-update', '-c', args.configuration]
    if not args.skip_build:
        run(*swift, env=env)
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
        run('python3', REPO / 'scripts/test_plugins.py', '--app', app, '--packages', packages, '-v')
        if args.gui:
            config = stage / 'config'
            config.mkdir()
            (config / 'config.yml').write_text('window: { mode: window, activate_at_launch: false }\nlocal_server: { enabled: false }\n')
            # This exact test process exits itself after probing. No pid/name-based kill.
            run(contents / 'MacOS/Tilr', '--config', config, '--no-updates', '--probe',
                '--site', ROOT.parent / 'web/site', timeout=120)


if __name__ == '__main__':
    main()
