"""Embed bootstrap plugin packages; installed versions are selected independently."""
from pathlib import Path
import shutil
import subprocess
import re
import json
import hashlib
import plistlib

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT / 'native-plugins'


def plugin_inventory(app):
    """Read the actual packaged versions, independently of source manifests."""
    result = []
    for package in sorted((Path(app) / 'Contents/PlugIns').glob('*.tilrplugin')):
        manifest = json.loads((package / 'Contents/Resources/manifest.json').read_text())
        with (package / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        if (package.name != f"{manifest['id']}.tilrplugin"
                or not re.fullmatch(r'[a-z][a-z0-9-]*', manifest['id'])
                or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', manifest['version'])
                or type(manifest['abi']) is not int or manifest['abi'] != 1
                or info.get('CFBundleShortVersionString') != manifest['version']
                or info.get('CFBundleExecutable') != 'Plugin'):
            raise ValueError(f'Invalid native plugin metadata: {package}')
        with (package / 'Contents/MacOS/Plugin').open('rb') as binary:
            checksum = hashlib.file_digest(binary, 'sha256').hexdigest()
        result.append(dict(id=manifest['id'], version=manifest['version'], abi=manifest['abi'], sha256=checksum))
    return result


def describe_plugins(inventory):
    return ', '.join(f"{p['id']} {p['version']} (ABI {p['abi']})" for p in inventory) or 'none'


def bundle_plugins(app, arch, identity='-', source=None):
    # The vendor repository's manifests are the release set, including new vendors.
    ids = []
    for path in sorted((REPO / 'manifests').glob('*.json')):
        manifest = json.loads(path.read_text())
        if manifest.get('id') != path.stem or not re.fullmatch(r'[a-z][a-z0-9-]*', path.stem):
            raise ValueError(f'Invalid vendor plugin manifest: {path}')
        ids.append(path.stem)
    if not ids:
        raise ValueError(f'No vendor plugin manifests found in {REPO}')
    destination = Path(app) / 'Contents/PlugIns'
    destination.mkdir(parents=True, exist_ok=True)
    if source is None:
        subprocess.run(['python3', str(REPO / 'scripts/plugin.py'), 'build', *ids, '--arch', arch,
                        '--identity', identity, '--output', str(destination)], check=True)
    else:
        for id in ids:
            package = Path(source) / f'{id}.tilrplugin'
            subprocess.run(['codesign', '--verify', '--strict', str(package)], check=True)
            subprocess.run(['lipo', str(package / 'Contents/MacOS/Plugin'), '-verify_arch', arch], check=True)
            target = destination / package.name
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(package, target)
    for package in destination.glob('*.tilrplugin'):
        subprocess.run(['codesign', '--verify', '--strict', str(package)], check=True)
    if {p.stem for p in destination.glob('*.tilrplugin')} != set(ids):
        raise ValueError('Bundled plugins differ from the vendor manifest set')


def verify_plugin_publishers(app):
    def team(path):
        result = subprocess.run(['codesign', '-dv', '--verbose=4', str(path)], check=True, capture_output=True, text=True)
        match = re.search(r'^TeamIdentifier=(.+)$', result.stderr, re.M)
        return None if match is None or match[1] == 'not set' else match[1]
    publisher = team(app)
    for package in (Path(app) / 'Contents/PlugIns').glob('*.tilrplugin'):
        if team(package) != publisher:
            raise ValueError(f'Native plugin has another signing team: {package}')
