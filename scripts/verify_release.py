#!/usr/bin/env python3
"""Verify the exact notarized DMG; optionally launch a separate local test instance."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile

from publish import validate_manifest, digest
from release import ROOT
from bundle_server import verify_server


def run(*args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def verify(directory, launch=False):
    meta, dmg = validate_manifest(directory)
    # Check the archive and the app INSIDE it, not just the sibling .app.
    run("hdiutil", "verify", dmg)
    run("codesign", "--verify", "--strict", dmg)
    run("xcrun", "stapler", "validate", dmg)
    (ROOT / "build/local-tests").mkdir(parents=True, exist_ok=True)
    copied = None
    with tempfile.TemporaryDirectory(prefix="mount-", dir=ROOT / "build/local-tests") as temp:
        mount = Path(temp) / "volume"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
        try:
            app = mount / "Tilr.app"
            run("codesign", "--verify", "--deep", "--strict", app)
            run("xcrun", "stapler", "validate", app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
            with (app / "Contents/Info.plist").open("rb") as file:
                info = plistlib.load(file)
            expected = {"CFBundleIdentifier": "dev.tilr.mac", "CFBundleVersion": str(meta["build"]),
                        "CFBundleShortVersionString": meta["version"], "SUFeedURL": meta["feed"],
                        "SUPublicEDKey": meta["public_key"]}
            if any(info.get(key) != value for key, value in expected.items()):
                raise ValueError("DMG's embedded application differs from release metadata")
            if meta.get("packaging") == 1:
                from release_packaging import audit
                audit(app, meta["arch"])
            binary = app / "Contents/MacOS/Tilr"
            run("lipo", "-verify_arch", meta["arch"], binary)
            verify_server(app, meta["version"], meta["build"], meta["arch"])
            server = app / "Contents/Helpers/tilr-server"
            run("lipo", "-verify_arch", meta["arch"], server)
            run("codesign", "--verify", "--strict", server)
            if digest(binary) != digest(directory / "Tilr.app/Contents/MacOS/Tilr"):
                raise ValueError("DMG contains a different application executable")
            if launch:
                if platform.machine() != meta["arch"]:
                    raise ValueError("Launch on a matching Mac architecture; Intel acceptance requires an Intel Mac")
                test_dir = Path(tempfile.mkdtemp(prefix=f"{meta['build']}-{meta['arch']}-", dir=ROOT / "build/local-tests"))
                copied = test_dir / "Tilr.app"
                run("ditto", app, copied)
        finally:
            run("hdiutil", "detach", mount)
    report = dict(sha256=meta["sha256"], version=meta["version"], build=meta["build"],
                  arch=meta["arch"], artifact_checks="passed", gui_test="not confirmed")
    (directory / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print("DMG integrity, embedded application, architecture, signatures and stapling verified.")
    if copied:
        config = copied.parent / "config"
        config.mkdir()
        (config / "config.yml").write_text("window: { mode: window, inset: { x: 200, y: 150 } }\n")
        # Different config = different socket, storage and PID; do not touch the user's Tilr.
        run("open", "-n", copied, "--args", "--config", config,
            "--site", copied.parent / "empty-site", "--no-updates")
        print(f"Launched a separate test instance: {copied.parent}")
        print("Check the welcome page and window controls manually. Launch request is not a GUI test pass.")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path)
    parser.add_argument("--launch", action="store_true", help="Launch matching architecture with isolated config and updates disabled")
    args = parser.parse_args()
    verify(args.release.resolve(), args.launch)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Verification stopped: {error}")
