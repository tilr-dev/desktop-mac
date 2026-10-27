"""Exercise real Sparkle routing and native controls in separate app launches.

Build an isolated Swift package to avoid requiring unrelated Gitpm/server artifacts.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid

from release import ROOT, app_info


class AppUpdateIntegrationTests(unittest.TestCase):
    def test_preferences_route_real_sparkle_and_survive_relaunch(self):
        package = ROOT / '.build/app-update-tests-package'
        package.mkdir(parents=True, exist_ok=True)
        (package / 'Package.swift').write_text('''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "AppUpdateTests", platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")],
    targets: [.target(name: "AppUpdates", dependencies: ["Sparkle"]),
              .executableTarget(name: "UpdateTests", dependencies: ["AppUpdates", "Sparkle"])])
''')
        sources = package / 'Sources'
        sources.mkdir(exist_ok=True)
        if not (sources / 'AppUpdates').exists():
            (sources / 'AppUpdates').symlink_to(ROOT / 'Sources/AppUpdates', target_is_directory=True)
        tests = sources / 'UpdateTests'
        tests.mkdir(exist_ok=True)
        shutil.copyfile(ROOT / 'scripts/test_app_updates.swift', tests / 'UpdateTests.swift')
        scratch = ROOT / '.build/app-update-tests'
        command = ['swift', 'build', '--disable-sandbox', '--build-system', 'native',
                   '--package-path', str(package),
                   '--scratch-path', str(scratch)]
        subprocess.run(command, check=True)
        binary_dir = Path(subprocess.check_output(command + ['--show-bin-path'], text=True).strip())
        framework = scratch / 'artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Tilr.app'
            contents = app / 'Contents'
            (contents / 'MacOS').mkdir(parents=True)
            (contents / 'Frameworks').mkdir()
            subprocess.run(['ditto', str(framework), str(contents / 'Frameworks/Sparkle.framework')], check=True)
            binary = contents / 'MacOS/UpdateTests'
            shutil.copy2(binary_dir / 'UpdateTests', binary)
            # SwiftPM's framework rpath is @loader_path, not the installed app layout.
            subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(binary)], check=True)
            template = plistlib.loads((ROOT / 'Info.plist').read_bytes())
            info = app_info(template, '0.1.0', 1, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')
            info.update(CFBundleExecutable='UpdateTests', SUEnableAutomaticChecks=False)
            (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
            before = (contents / 'Info.plist').read_bytes()
            env = {**os.environ, 'TILR_UPDATE_FEED': 'https://invalid.example/ignored.xml'}
            for arch in ('arm64', 'x86_64'):
                suite = 'dev.tilr.update-tests.' + uuid.uuid4().hex
                for mode in ('enable', 'disable', 'stable'):
                    subprocess.run([str(binary), mode, suite, arch], env=env, check=True)
                    self.assertEqual((contents / 'Info.plist').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
