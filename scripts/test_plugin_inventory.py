import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import bundle_plugins
from bundle_plugins import plugin_inventory


class InventoryTests(unittest.TestCase):
    def test_release_bundles_additional_vendor_plugins(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo = root / 'vendor'
            (repo / 'manifests').mkdir(parents=True)
            ids = ['audio', 'browser-webkit', 'my-vendor-plugin']
            source = root / 'packages'
            for id in ids:
                (repo / f'manifests/{id}.json').write_text(json.dumps({'id': id}))
                (source / f'{id}.tilrplugin').mkdir(parents=True)
            app = root / 'Tilr.app'
            with patch.object(bundle_plugins, 'REPO', repo), patch.object(bundle_plugins.subprocess, 'run') as run:
                bundle_plugins.bundle_plugins(app, 'arm64', source=source)
                self.assertEqual({p.stem for p in (app / 'Contents/PlugIns').iterdir()}, set(ids))
                bundle_plugins.bundle_plugins(app, 'arm64', identity='vendor identity')
                command = next(call.args[0] for call in run.call_args_list if call.args[0][0] == 'python3')
                self.assertEqual(command[3:6], ids)
                self.assertIn('vendor identity', command)

    def test_inventory_tracks_packaged_version_and_binary(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / 'Tilr.app'
            contents = app / 'Contents/PlugIns/audio.tilrplugin/Contents'
            (contents / 'Resources').mkdir(parents=True)
            (contents / 'MacOS').mkdir()
            (contents / 'Resources/manifest.json').write_text(json.dumps(dict(id='audio', version='0.2.0', abi=1)))
            (contents / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.2.0', CFBundleExecutable='Plugin')))
            binary = contents / 'MacOS/Plugin'
            binary.write_bytes(b'first build')
            original = plugin_inventory(app)
            self.assertEqual(original[0]['version'], '0.2.0')
            binary.write_bytes(b'changed build')
            self.assertNotEqual(original, plugin_inventory(app))
            (contents / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.1.0', CFBundleExecutable='Plugin')))
            with self.assertRaisesRegex(ValueError, 'metadata'):
                plugin_inventory(app)


if __name__ == '__main__':
    unittest.main()
