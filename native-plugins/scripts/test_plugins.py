#!/usr/bin/env python3
"""Real signed-package/host tests. Pass --app TEST_APP --packages DIST_DIR."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import plugin


class Packages(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tilr-native-packages-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'config'
        self.config.mkdir()
        (self.config / 'config.yml').write_text('native_plugins: { enabled: [audio] }\n')
        self.directory = self.config / 'native-plugins'
        self.source = self.root / 'audio.tilrplugin'
        shutil.copytree(PACKAGES / 'audio.tilrplugin', self.source)

    def check_host(self, success=True):
        result = subprocess.run([str(APP / 'Contents/MacOS/Tilr'), '--config', str(self.config),
                                 '--check-native-plugins'], capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def resign(self, **updates):
        file = self.source / 'Contents/Resources/manifest.json'
        data = json.loads(file.read_text())
        data.update(updates)
        file.write_text(json.dumps(data))
        info = self.source / 'Contents/Info.plist'
        plist = plistlib.loads(info.read_bytes())
        plist.update(CFBundleVersion=data['version'], CFBundleShortVersionString=data['version'])
        info.write_bytes(plistlib.dumps(plist))
        subprocess.run(['codesign', '--force', '--sign', '-', str(self.source)], check=True, capture_output=True)

    def install(self):
        return plugin.install(self.source, self.directory, app=APP, development=True)

    def test_bundled_modules_load(self):
        (self.config / 'config.yml').write_text('native_plugins: { enabled: [audio, browser-webkit] }\n')
        text = self.check_host()
        self.assertIn('audio 0.1.0 ABI 1', text)
        self.assertIn('browser-webkit 0.1.0 ABI 1', text)

    def test_independent_install_update_and_rollback(self):
        binary = APP / 'Contents/MacOS/Tilr'
        before = hashlib.sha256(binary.read_bytes()).hexdigest()
        self.install()
        self.assertIn(str(self.directory), self.check_host())
        self.resign(version='0.1.1')
        self.install()
        self.assertIn('audio 0.1.1 ABI 1', self.check_host())
        plugin.rollback('audio', self.directory, app=APP, development=True)
        self.assertIn('audio 0.1.0 ABI 1', self.check_host())
        self.assertEqual(before, hashlib.sha256(binary.read_bytes()).hexdigest())
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True, capture_output=True)

    def test_invalid_package_cannot_change_active_version(self):
        self.install()
        active = self.directory / 'audio/active.json'
        before = active.read_bytes()
        file = self.source / 'Contents/Resources/manifest.json'
        file.write_text(file.read_text().replace('0.1.0', '0.1.1'))
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertEqual(before, active.read_bytes())

    def test_installed_tampering_is_rejected_by_host(self):
        self.install()
        file = self.directory / 'audio/0.1.0.tilrplugin/Contents/Resources/manifest.json'
        file.write_text(file.read_text() + ' ')
        self.assertIn('invalid code signature', self.check_host(False))

    def test_third_party_mode_still_rejects_tampered_packages(self):
        (self.config / 'config.yml').write_text('native_plugins: { enabled: [audio], allow_third_party: true }\n')
        self.install()
        file = self.directory / 'audio/0.1.0.tilrplugin/Contents/Resources/manifest.json'
        file.write_text(file.read_text() + ' ')
        self.assertIn('invalid code signature', self.check_host(False))

    def test_installer_requires_opt_in_for_another_publisher(self):
        for publisher in ['OTHER_TEAM', None]:
            with patch.object(plugin, 'signature', side_effect=[publisher, 'TILR_TEAM']):
                with self.assertRaisesRegex(ValueError, 'signing team'):
                    plugin.verify(self.source, APP)
            with patch.object(plugin, 'signature', side_effect=[publisher, 'TILR_TEAM']):
                self.assertEqual(plugin.verify(self.source, APP, allow_third_party=True)['id'], 'audio')

    def test_installer_probes_target_config_before_activation(self):
        # Invalid permission config must fail closed before executing plugin code.
        (self.config / 'config.yml').write_text('native_plugins: { allow_third_party: [invalid] }\n')
        with self.assertRaises(subprocess.CalledProcessError):
            plugin.install(self.source, self.directory, app=APP, allow_third_party=True)
        self.assertFalse((self.directory / 'audio/active.json').exists())

    def test_incompatible_abi_rejected_by_installer_and_host(self):
        self.resign(abi=99)
        with self.assertRaises(ValueError):
            self.install()
        folder = self.directory / 'audio'
        folder.mkdir(parents=True)
        shutil.copytree(self.source, folder / '0.1.0.tilrplugin')
        (folder / 'active.json').write_text('{"version":"0.1.0"}')
        self.assertIn('incompatible native plugin manifest', self.check_host(False))

    def test_active_version_must_match_signed_manifest(self):
        folder = self.directory / 'audio'
        folder.mkdir(parents=True)
        shutil.copytree(self.source, folder / '9.0.0.tilrplugin')
        (folder / 'active.json').write_text('{"version":"9.0.0"}')
        self.assertIn('incompatible native plugin manifest', self.check_host(False))

    def test_versions_immutable_and_paths_validated(self):
        self.install()
        with self.assertRaises(ValueError):
            self.install()
        for value in ['../audio', '/tmp/audio', 'a/b', '']:
            with self.assertRaises(ValueError):
                plugin.component(value)
        (self.directory / 'audio/active.json').write_text('{"version":"../../outside"}')
        self.assertIn('invalid active version', self.check_host(False))

    def test_missing_factory_rejected_by_host(self):
        source = self.root / 'empty.c'
        source.write_text('int not_a_plugin(void) { return 1; }\n')
        subprocess.run(['clang', '-dynamiclib', str(source), '-o', str(self.source / 'Contents/MacOS/Plugin')], check=True, capture_output=True)
        self.resign()
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertFalse((self.directory / 'audio/active.json').exists())
        folder = self.directory / 'audio'
        shutil.copytree(self.source, folder / '0.1.0.tilrplugin')
        (folder / 'active.json').write_text('{"version":"0.1.0"}')
        self.assertIn('missing ABI 1 entry point', self.check_host(False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--packages', type=Path, required=True)
    args, extra = parser.parse_known_args()
    APP, PACKAGES = args.app.resolve(), args.packages.resolve()
    unittest.main(argv=[__file__, *extra])
