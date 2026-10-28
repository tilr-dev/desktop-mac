"""Independent server artifacts, pinned and reused unchanged by app releases."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_payload(directory, arch, protocol, app_build, manifest_path=None):
    meta = json.loads((manifest_path or directory / "app-managed.json").read_text())
    if meta["arch"] != arch or meta["protocolVersion"] != protocol or meta["build"] < 1:
        raise ValueError("Bundled server architecture or protocol does not match the application")
    if not meta["minAppBuild"] <= app_build or (meta.get("maxAppBuild") is not None and app_build > meta["maxAppBuild"]):
        raise ValueError("Bundled server does not support this app build")
    if digest(directory / "tilrd") != meta["sha256"]:
        raise ValueError("Bundled server checksum mismatch")
    return meta


def bundle_server(app, arch, app_build, root=ROOT):
    if arch not in TARGETS:
        raise ValueError("Use the separate arm64 and x86_64 app releases for independent server updates")
    pin = json.loads((root / "server-release.json").read_text())
    releases = Path(os.environ.get("TILR_SERVER_RELEASE_ROOT", root / "build/server-releases"))
    directory = releases / f"{pin['version']}-{pin['build']}-{arch}"
    if not (directory / "release.json").exists():
        raise ValueError(f"Acquire the pinned upstream server release first: scripts/release_server.py --version {pin['version']} --build {pin['build']} --protocol-version {pin['protocolVersion']} --arch {arch}; missing {directory}")
    from fetch_server import validate_completed
    validate_completed(directory, pin["version"], pin["build"], arch, pin["protocolVersion"])
    receipt = json.loads((directory / "release.json").read_text())
    meta = validate_payload(directory, arch, pin["protocolVersion"], app_build)
    if meta["version"] != pin["version"] or meta["build"] != pin["build"] or receipt.get("manifest") != meta:
        raise ValueError("Server artifact differs from the pinned/completed release")
    helpers = app / "Contents/Helpers"
    helpers.mkdir(parents=True, exist_ok=True)
    resources = app / "Contents/Resources/server"
    resources.mkdir(parents=True, exist_ok=True)
    for executable in ("tilrd", "tilr"):
        subprocess.run(["ditto", str(directory / executable), str(helpers / executable)], check=True)
    subprocess.run(["ditto", str(directory / "app-managed.json"), str(resources / "app-managed.json")], check=True)
    subprocess.run(["ditto", str(directory / "client.json"), str(resources / "client.json")], check=True)
    for executable in ("tilrd", "tilr"):
        subprocess.run(["codesign", "--verify", "--strict", str(helpers / executable)], check=True)
    return meta


def verify_server(app, version, build, arch):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    meta = validate_payload(app / "Contents/Helpers", arch, info["TilrServerProtocolVersion"], build,
                            app / "Contents/Resources/server/app-managed.json")
    client = json.loads((app / "Contents/Resources/server/client.json").read_text())
    if client.get("version") != meta["serverVersion"] or digest(app / "Contents/Helpers/tilr") != client.get("sha256"):
        raise ValueError("Bundled client differs from the pinned upstream release")
    from fetch_server import check_binary
    if check_binary(app / "Contents/Helpers/tilr", arch, meta["version"], "tilr") != client["version"]:
        raise ValueError("Bundled client version differs from its receipt")
    if meta["build"] != info["TilrBundledServerBuild"] or meta["version"] != info["TilrBundledServerVersion"]:
        raise ValueError("Bundled server differs from the app's pinned server release")
    return meta
