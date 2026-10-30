"""Independent server artifacts: the latest stable release at acquisition, reused unchanged by app releases."""
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


def bundle_server(app, arch, protocol, root=ROOT):
    if arch not in TARGETS:
        raise ValueError("Use the separate arm64 and x86_64 app releases for independent server updates")
    releases = Path(os.environ.get("TILR_SERVER_RELEASE_ROOT", root / "build/server-releases"))
    selected = releases / "selected.json"
    if not selected.exists():
        raise ValueError(f"Acquire the latest upstream server release first: python3 scripts/fetch_server.py; missing {selected}")
    release = json.loads(selected.read_text())
    if release.get("protocolVersion") != protocol:
        raise ValueError("Bundled server protocol does not match the application")
    directory = releases / f"{release['version']}-{arch}"
    from fetch_server import validate_completed
    meta = validate_completed(directory, release["version"], arch, protocol)
    helpers = app / "Contents/Helpers"
    helpers.mkdir(parents=True, exist_ok=True)
    for executable in ("tilrd", "tilr"):
        subprocess.run(["ditto", str(directory / executable), str(helpers / executable)], check=True)
    for executable in ("tilrd", "tilr"):
        subprocess.run(["codesign", "--verify", "--strict", str(helpers / executable)], check=True)
    return meta


def verify_server(app, arch):
    """The bundle carries the pair only: no manifest or version keys select or pin it."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not isinstance(info.get("TilrServerProtocolVersion"), int):
        raise ValueError("Application has no supported server protocol")
    if any(key.startswith("TilrBundledServer") for key in info) or (app / "Contents/Resources/server").exists():
        raise ValueError("Application bundles server pin metadata")
    from fetch_server import check_binary
    identity = check_binary(app / "Contents/Helpers/tilrd", arch, None)
    if check_binary(app / "Contents/Helpers/tilr", arch, None, "tilr") != identity:
        raise ValueError("Bundled client differs from the bundled server release")
    return identity
