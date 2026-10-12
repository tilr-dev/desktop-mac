#!/usr/bin/env python3
"""Build, verify, install and roll back independently compiled Tilr native plugins."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ABI = 1


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def component(value, version=False):
    pattern = r"[0-9]+\.[0-9]+\.[0-9]+" if version else r"[a-z][a-z0-9-]*"
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ValueError(f"Invalid {'version' if version else 'plugin id'}: {value!r}")
    return value


def manifest(package):
    data = json.loads((package / 'Contents/Resources/manifest.json').read_text())
    component(data['id'])
    component(data['version'], True)
    if data['abi'] != ABI:
        raise ValueError(f"Unsupported plugin ABI {data['abi']}")
    minimum = data.get('minOS', '')
    if not re.fullmatch(r'[0-9]+\.[0-9]+', minimum):
        raise ValueError('Invalid minOS')
    if tuple(map(int, platform.mac_ver()[0].split('.')[:2])) < tuple(map(int, minimum.split('.'))):
        raise ValueError(f"Requires macOS {minimum}")
    if not isinstance(data.get('bridges'), dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data['bridges'].items()):
        raise ValueError('bridges must map handler names to channels')
    for key in ('services', 'events'):
        if not isinstance(data.get(key), list) or not all(isinstance(v, str) for v in data[key]):
            raise ValueError(f'{key} must be a string array')
    return data


def signature(path):
    run('codesign', '--verify', '--strict', path, capture_output=True)
    info = run('codesign', '-dv', '--verbose=4', path, capture_output=True, text=True).stderr
    team = re.search(r'^TeamIdentifier=(.+)$', info, re.M)
    return None if team is None or team[1] == 'not set' else team[1]


def verify(package, app=None, development=False, arch=None, allow_third_party=False):
    if allow_third_party and app is None:
        raise ValueError('--allow-third-party requires --app and its runtime permission')
    package = Path(package)
    if package.is_symlink() or any(p.is_symlink() for p in package.rglob('*')):
        raise ValueError('Plugin packages may not contain symlinks')
    team = signature(package)
    if app:
        host_team = signature(app)
        if not allow_third_party and (team != host_team or (team is None and not development)):
            raise ValueError('Plugin and app must share a signing team (ad-hoc requires --development)')
    elif not development:
        raise ValueError('Use --app /path/to/Tilr.app to verify publisher, or --development for a local build')
    elif team is not None:
        raise ValueError('Use --app to verify a Developer ID plugin')
    data = manifest(package)
    with (package / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleExecutable') != 'Plugin' or info.get('CFBundleShortVersionString') != data['version']:
        raise ValueError('Info.plist and manifest disagree')
    run('lipo', '-verify_arch', arch or platform.machine(), package / 'Contents/MacOS/Plugin', capture_output=True)
    return data


def build(ids=None, *, configuration='release', arch=None, identity='-', output=None, version=None):
    arch = arch or platform.machine()
    output = Path(output or ROOT / 'dist' / arch)
    output.mkdir(parents=True, exist_ok=True)
    ids = ids or [p.stem for p in sorted((ROOT / 'manifests').glob('*.json'))]
    manifests = []
    for id in ids:
        component(id)
        data = json.loads((ROOT / 'manifests' / f'{id}.json').read_text())
        if data['id'] != id:
            raise ValueError('Manifest id differs from its filename')
        manifests.append(data)
    env = os.environ.copy()
    cache = ROOT / '.build/module-cache'
    env.setdefault('CLANG_MODULE_CACHE_PATH', str(cache))
    env.setdefault('SWIFTPM_MODULECACHE_OVERRIDE', str(cache))
    command = ['swift', 'build', '--build-system', 'native', '--disable-sandbox', '--package-path', ROOT,
               '--scratch-path', ROOT / '.build' / arch, '-c', configuration, '--arch', arch]
    for data in manifests:
        run(*command, '--product', data['product'], env=env)
    binary_dir = Path(run(*command, '--show-bin-path', env=env, capture_output=True, text=True).stdout.strip())
    packages = []
    for data in manifests:
        id = data['id']
        if version:
            data['version'] = component(version, True)
        with tempfile.TemporaryDirectory(prefix='.package-', dir=output) as temp:
            package = Path(temp) / f'{id}.tilrplugin'
            contents = package / 'Contents'
            (contents / 'MacOS').mkdir(parents=True)
            (contents / 'Resources').mkdir()
            shutil.copy2(binary_dir / f'lib{data.pop("product")}.dylib', contents / 'MacOS/Plugin')
            # Set a package-relative install name, never a checkout/build path.
            run('install_name_tool', '-id', '@rpath/Plugin', contents / 'MacOS/Plugin')
            (contents / 'Resources/manifest.json').write_text(json.dumps(data, indent=2) + '\n')
            with (contents / 'Info.plist').open('wb') as stream:
                plistlib.dump(dict(CFBundleIdentifier=f'dev.tilr.native.{id}', CFBundleName=id,
                                  CFBundlePackageType='BNDL', CFBundleExecutable='Plugin',
                                  CFBundleVersion=data['version'], CFBundleShortVersionString=data['version'],
                                  LSMinimumSystemVersion=data['minOS']), stream)
            args = ['codesign', '--force', '--sign', identity]
            if identity != '-':
                args += ['--options', 'runtime', '--timestamp']
            run(*args, package)
            signature(package)
            target = output / package.name
            if target.exists():
                shutil.rmtree(target)
            package.rename(target)
            packages.append(target)
    return packages


@contextmanager
def locked(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def atomic_json(path, data):
    fd, name = tempfile.mkstemp(prefix='.active-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump(data, file)
            file.write('\n')
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def activate(folder, version):
    active = folder / 'active.json'
    old = json.loads(active.read_text()) if active.exists() else {}
    if old.get('version') == version:
        return
    data = {'version': version}
    if old.get('version'):
        data['previous'] = old['version']
    atomic_json(active, data)


def probe(package, app, timeout, config=None):
    if app:
        command = [Path(app) / 'Contents/MacOS/Tilr', '--check-native-plugin', package]
        if config is not None:
            command += ['--config', config]
        run(*command, capture_output=True, timeout=timeout)


def install(package, directory, *, app=None, development=False, probe_timeout=30, allow_third_party=False, config=None):
    data = verify(package, app, development, allow_third_party=allow_third_party)
    folder = Path(directory) / data['id']
    with locked(folder):
        destination = folder / f'{data["version"]}.tilrplugin'
        if destination.exists():
            raise ValueError(f'{data["id"]} {data["version"]} already installed; build a new version')
        with tempfile.TemporaryDirectory(prefix='.install-', dir=folder) as temp:
            staged = Path(temp) / destination.name
            shutil.copytree(package, staged)
            verify(staged, app, development, allow_third_party=allow_third_party)  # Verify the copied bytes, not just the source.
            probe(staged, app, probe_timeout, config or Path(directory).parent)
            staged.rename(destination)
        activate(folder, data['version'])
    return data


def rollback(id, directory, *, app=None, development=False, probe_timeout=30, allow_third_party=False, config=None):
    folder = Path(directory) / component(id)
    with locked(folder):
        active = json.loads((folder / 'active.json').read_text())
        version = component(active.get('previous'), True)
        verify(folder / f'{version}.tilrplugin', app, development, allow_third_party=allow_third_party)
        probe(folder / f'{version}.tilrplugin', app, probe_timeout, config or Path(directory).parent)
        activate(folder, version)
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    builder = sub.add_parser('build')
    builder.add_argument('ids', nargs='*')
    builder.add_argument('--configuration', choices=['debug', 'release'], default='release')
    builder.add_argument('--arch', choices=['arm64', 'x86_64'], default=platform.machine())
    builder.add_argument('--identity', default='-')
    builder.add_argument('--output', type=Path)
    builder.add_argument('--version')
    for name in ['verify', 'install', 'rollback', 'list']:
        command = sub.add_parser(name)
        if name in ['verify', 'install']:
            command.add_argument('package', type=Path)
        if name == 'rollback':
            command.add_argument('id')
        command.add_argument('--directory', type=Path, default=Path.home() / 'Library/Application Support/dev.tilr.mac/native-plugins')
        if name != 'list':
            command.add_argument('--app', type=Path)
            command.add_argument('--development', action='store_true')
            command.add_argument('--allow-third-party', action='store_true', help='Accept another publisher/ad-hoc package; the target app config must also allow it')
            command.add_argument('--config', type=Path, help='Target instance config directory (default: parent of --directory)')
            command.add_argument('--probe-timeout', type=float, default=30, help='Seconds allowed for the app ABI probe')
    args = parser.parse_args()
    if args.command == 'build':
        for path in build(args.ids, configuration=args.configuration, arch=args.arch, identity=args.identity, output=args.output, version=args.version):
            print(path)
    elif args.command == 'verify':
        print(json.dumps(verify(args.package, args.app, args.development, allow_third_party=args.allow_third_party), indent=2))
    elif args.command == 'install':
        print(json.dumps(install(args.package, args.directory, app=args.app, development=args.development, probe_timeout=args.probe_timeout, allow_third_party=args.allow_third_party, config=args.config), indent=2))
        print('Installed. Restart Tilr to activate the native module; the application bundle is unchanged.')
    elif args.command == 'rollback':
        print('Selected', rollback(args.id, args.directory, app=args.app, development=args.development, probe_timeout=args.probe_timeout, allow_third_party=args.allow_third_party, config=args.config), 'for the next launch.')
    else:
        for path in sorted(args.directory.glob('*/active.json')):
            print(path.parent.name, path.read_text().strip())


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
