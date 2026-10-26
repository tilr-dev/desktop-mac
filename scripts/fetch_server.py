#!/usr/bin/env python3
"""Download the pinned server release when it is already published, for an app release runner.

A rebuilt server has different signed bytes, and a published release number never
changes contents; so a runner reuses the public artifact instead of rebuilding it.
Exit 0: both architectures fetched; exit 3: the pinned build is not published yet.
"""
from release_console import ArgumentParser, success, failure
import base64
import json
from pathlib import Path
import re
import subprocess
import tempfile

from bundle_server import ROOT, TARGETS, digest
from publish import fetch
from release_server import feed_url, release_url

NOT_PUBLISHED = 3
TEAM = "V57FF3MX26"


def published_manifest(arch, version, build, channel, temp):
    """The pinned release from the public feed, or None when the feed or the build is absent."""
    path = temp / f"feed-{arch}.json"
    if not fetch(feed_url(arch, channel), path):
        return None
    signed = json.loads(path.read_text())
    payload = json.loads(base64.b64decode(signed["payload"], validate=True))
    if any(payload.get(k) != v for k, v in dict(schema=1, component="tilrd", arch=arch, channel=channel).items()):
        raise ValueError(f"Server feed for {arch} is for another track")
    entries = [item for item in payload["releases"] if item["manifest"]["build"] == build]
    if not entries:
        return None
    manifest = entries[0]["manifest"]
    if manifest.get("version") != version or manifest.get("arch") != arch:
        raise ValueError(f"Published server build {build} ({arch}) is not version {version}")
    if entries[0]["url"] != release_url(manifest):
        raise ValueError("Server feed points outside the immutable release location")
    return manifest


def check_signature(binary):
    """HTTPS plus the checksum from the feed, then our Developer ID with a secure timestamp."""
    subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
    details = subprocess.run(["codesign", "-dv", "--verbose=2", str(binary)], check=True,
                             capture_output=True, text=True).stderr
    if f"TeamIdentifier={TEAM}" not in details or not re.search(r"^Timestamp=", details, re.M):
        raise ValueError("Published server is not signed by the Rexuni Developer ID with a timestamp")


def download(manifest, temp):
    remote = temp / f"tilrd-{manifest['arch']}"
    if not fetch(release_url(manifest), remote) or digest(remote) != manifest["sha256"]:
        raise ValueError(f"Published server {manifest['arch']} is missing or differs from its feed checksum")
    check_signature(remote)
    return remote


def install(destination, manifest, remote, key):
    destination.mkdir(parents=True, exist_ok=False)
    remote.rename(destination / "tilrd")
    (destination / "tilrd").chmod(0o755)
    (destination / "app-managed.json").write_text(json.dumps(manifest, indent=2) + "\n")
    receipt = dict(preview=False, manifest=manifest, public_key=key, fetched=release_url(manifest))
    (destination / "release.json").write_text(json.dumps(receipt, indent=2) + "\n")


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=("stable", "beta"), default="stable")
    parser.add_argument("--public-key", required=True, help="The release Sparkle/server public key (base64)")
    args = parser.parse_args()
    pin = json.loads((ROOT / "server-release.json").read_text())
    with tempfile.TemporaryDirectory(prefix="fetch-server-") as temp:
        temp = Path(temp)
        manifests = {arch: published_manifest(arch, pin["version"], pin["build"], args.channel, temp) for arch in TARGETS}
        missing = [arch for arch, manifest in manifests.items() if manifest is None]
        if len(missing) == len(TARGETS):
            print(f"Pinned server {pin['version']}-{pin['build']} is not published; build it.", flush=True)
            return NOT_PUBLISHED
        if missing:
            raise ValueError(f"Pinned server is published for some architectures only (missing {', '.join(missing)}); "
                             "finish its publication before an app release")
        for manifest in manifests.values():
            if manifest["protocolVersion"] != pin["protocolVersion"]:
                raise ValueError(f"Published server protocol {manifest['protocolVersion']} differs from the pin")
        # Verify both architectures before writing either completed release.
        downloads = {arch: download(manifest, temp) for arch, manifest in manifests.items()}
        for arch, manifest in manifests.items():
            output = ROOT / "build/server-releases" / f"{pin['version']}-{pin['build']}-{arch}"
            install(output, manifest, downloads[arch], args.public_key)
            success(f"Fetched published server: {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        failure(f"Server fetch stopped: {error}")
        raise SystemExit(1)
