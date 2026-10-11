import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from release_packaging import audit, strip_executable, thin_tree
from release import embed_framework


@unittest.skipUnless(sys.platform == 'darwin', 'macOS packaging tools required')
class PackagingTests(unittest.TestCase):
    def test_real_sparkle_thinning_signatures_and_architecture_audit(self):
        framework = Path(__file__).resolve().parents[1] / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
        if not framework.exists():
            self.skipTest('Resolve Sparkle first')
        with tempfile.TemporaryDirectory() as tmp:
            for arch in ('arm64', 'x86_64'):
                app = Path(tmp) / arch / 'Tilr.app'
                embed_framework(app, framework, '-', arch)
                rows = audit(app, arch)
                self.assertGreaterEqual(len(rows), 5)
                target = app / 'Contents/Frameworks/Sparkle.framework'
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
                self.assertTrue((target / 'Versions/Current').is_symlink())
                self.assertTrue(all(r['architectures'] == [arch] for r in rows))
                with self.assertRaises(ValueError):
                    audit(app, 'x86_64' if arch == 'arm64' else 'arm64')

    def test_stripping_retains_original_outside_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / 'app/server'
            binary.parent.mkdir()
            shutil.copyfile('/usr/bin/true', binary)
            original = binary.read_bytes()
            strip_executable(binary, root / 'symbols')
            self.assertEqual((root / 'symbols/server.unstripped').read_bytes(), original)
            self.assertTrue(binary.exists())
            (binary.parent / 'debug.dSYM').mkdir()
            with self.assertRaisesRegex(ValueError, 'Build-only'):
                audit(binary.parent, 'arm64')

    def test_real_sparkle_delta_roundtrip_preserves_signed_bundle(self):
        tool = Path(__file__).resolve().parents[1] / '.build/artifacts/sparkle/Sparkle/bin/BinaryDelta'
        if not tool.exists():
            self.skipTest('Resolve Sparkle first')
        import plistlib
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            before, after, restored = [root / name for name in ('before.app', 'after.app', 'restored.app')]
            for app, build in ((before, '1'), (after, '2')):
                (app / 'Contents/MacOS').mkdir(parents=True)
                (app / 'Contents/Resources').mkdir()
                binary = app / 'Contents/MacOS/Tilr'
                shutil.copyfile('/usr/bin/true', binary)
                binary.chmod(0o755)
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
                    CFBundleExecutable='Tilr', CFBundleIdentifier='dev.tilr.delta-test',
                    CFBundlePackageType='APPL', CFBundleVersion=build)))
                (app / 'Contents/Resources/data').write_bytes(b'stable data' * 10000 + build.encode())
                subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
            delta = root / 'update.delta'
            subprocess.run([str(tool), 'create', str(before), str(after), str(delta)], check=True)
            subprocess.run([str(tool), 'apply', str(before), str(restored), str(delta)], check=True)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(restored)], check=True)
            for path in after.rglob('*'):
                if path.is_file():
                    self.assertEqual(path.read_bytes(), (restored / path.relative_to(after)).read_bytes())
