"""Independent server artifacts, pinned and reused unchanged by app releases."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
from release_packaging import strip_executable

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT.parent / "core"
TARGETS = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_server(destination, arch, version, build, sign, min_app_build=1, max_app_build=None, core=CORE):
    commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=core, text=True).strip()
    protocol = int(re.search(r"PROTOCOL_VERSION: u32 = (\d+)", (core / "crates/tilr-proto/src/lib.rs").read_text())[1])
    env = dict(os.environ, TILR_BUILD_VERSION=f"{version}-build{build}", TILR_BUILD_COMMIT=commit,
               MACOSX_DEPLOYMENT_TARGET="14.0")
    target = TARGETS[arch]
    subprocess.run(["cargo", "build", "--locked", "--release", "-p", "tilr-server", "--target", target,
                    "--target-dir", str(core / "target")],
                   cwd=core, env=env, check=True)
    destination.mkdir(parents=True, exist_ok=True)
    binary = destination / "tilr-server"
    subprocess.run(["ditto", str(core / "target" / target / "release/tilr-server"), str(binary)], check=True)
    subprocess.run(["lipo", str(binary), "-verify_arch", arch], check=True)
    strip_executable(binary, destination / "symbols")
    sign(binary)
    metadata = dict(version=version, build=build, arch=arch,
                    serverVersion=f"{version}-build{build}-{commit}", sha256=digest(binary),
                    protocolVersion=protocol, minAppBuild=min_app_build, maxAppBuild=max_app_build)
    (destination / "app-managed.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def validate_payload(directory, arch, protocol, app_build, manifest_path=None):
    meta = json.loads((manifest_path or directory / "app-managed.json").read_text())
    if meta["arch"] != arch or meta["protocolVersion"] != protocol or meta["build"] < 1:
        raise ValueError("Bundled server architecture or protocol does not match the application")
    if not meta["minAppBuild"] <= app_build or (meta.get("maxAppBuild") is not None and app_build > meta["maxAppBuild"]):
        raise ValueError("Bundled server does not support this app build")
    if digest(directory / "tilr-server") != meta["sha256"]:
        raise ValueError("Bundled server checksum mismatch")
    return meta


def bundle_server(app, arch, app_build, preview=False, root=ROOT):
    if arch not in TARGETS:
        raise ValueError("Use the separate arm64 and x86_64 app releases for independent server updates")
    pin = json.loads((root / "server-release.json").read_text())
    releases = Path(os.environ.get("TILR_SERVER_RELEASE_ROOT", root / "build/server-releases"))
    directory = releases / f"{pin['version']}-{pin['build']}-{arch}"
    if preview and not directory.exists():
        directory = directory.with_name(directory.name + "-preview")
    if not (directory / "release.json").exists():
        raise ValueError(f"Build the pinned server release first: scripts/release_server.py --version {pin['version']} --build {pin['build']} --arch {arch}; missing {directory}")
    receipt = json.loads((directory / "release.json").read_text())
    if not preview and receipt.get("preview") is not False:
        raise ValueError("A public app cannot bundle a preview server")
    meta = validate_payload(directory, arch, pin["protocolVersion"], app_build)
    if meta["version"] != pin["version"] or meta["build"] != pin["build"] or receipt.get("manifest") != meta:
        raise ValueError("Server artifact differs from the pinned/completed release")
    helpers = app / "Contents/Helpers"
    helpers.mkdir(parents=True, exist_ok=True)
    resources = app / "Contents/Resources/server"
    resources.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ditto", str(directory / "tilr-server"), str(helpers / "tilr-server")], check=True)
    subprocess.run(["ditto", str(directory / "app-managed.json"), str(resources / "app-managed.json")], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(helpers / "tilr-server")], check=True)
    return meta


def verify_server(app, version, build, arch):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("SUPublicEDKey") and (info.get("TilrServerPublicKey") != info["SUPublicEDKey"]
                                     or info.get("TilrServerFeedBaseURL") != "https://cdn.tilr.dev/server/macos"):
        raise ValueError("App does not configure the independent signed server feed")
    meta = validate_payload(app / "Contents/Helpers", arch, info["TilrServerProtocolVersion"], build,
                            app / "Contents/Resources/server/app-managed.json")
    if meta["build"] != info["TilrBundledServerBuild"] or meta["version"] != info["TilrBundledServerVersion"]:
        raise ValueError("Bundled server differs from the app's pinned server release")
    return meta
