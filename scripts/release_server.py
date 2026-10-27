#!/usr/bin/env python3
"""Independent macOS server release: acquire upstream artifacts, then publish the tested artifacts.

App releases only copy the server artifact pinned in ../server-release.json.
Server publication never rebuilds or publishes the Mac application/Sparkle feed.
"""
from release_console import ArgumentParser, success, failure
import base64
import fcntl
import json
from pathlib import Path
import re
import subprocess
import tempfile

from bundle_server import ROOT, TARGETS, digest
from fetch_server import acquire, validate_completed
from publish import CDN, fetch, put as put_object, run, sparkle_key, sparkle_public_key
from release_all import settings

TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def feed_url(arch, channel):
    return f"{CDN}/server/macos/{arch}/{channel}.json"


def release_url(manifest):
    return f"{CDN}/server/macos/{manifest['arch']}/releases/{manifest['version']}-{manifest['build']}/tilrd"


def next_feed(previous, manifest, size, channel):
    arch = manifest["arch"]
    header = dict(schema=1, component="tilrd", arch=arch, channel=channel)
    if previous is not None and any(previous.get(k) != v for k, v in header.items()):
        raise ValueError("Existing feed is for another server track")
    releases = list(previous["releases"]) if previous else []
    entry = dict(manifest=manifest, size=size, url=release_url(manifest))
    same = [item for item in releases if item["manifest"]["build"] == manifest["build"]]
    if same:
        if same != [entry]:
            raise ValueError("Published server release number already has different contents")
    else:
        if any(item["manifest"]["build"] > manifest["build"] for item in releases):
            raise ValueError("Server build must increase within this track")
        releases.append(entry)
    # Retain older protocol versions so older apps can still receive compatible updates.
    return dict(**header, releases=sorted(releases, key=lambda x: x["manifest"]["build"], reverse=True))


def verify_envelope(data, directory):
    signed = json.loads(data)
    payload = base64.b64decode(signed["payload"], validate=True)
    signature = signed["signature"]
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid server feed signature length")
    file = directory / "verify-payload.json"
    file.write_bytes(payload)
    run(TOOLS / "sign_update", *sparkle_key(), "--verify", file, signature)
    return json.loads(payload)


def signed_feed(feed, directory):
    payload = canonical(feed)
    file = directory / "payload.json"
    file.write_bytes(payload)
    signature = subprocess.check_output([str(TOOLS / "sign_update"), *sparkle_key(), "-p", str(file)], text=True).strip()
    if file.read_bytes() != payload:
        raise ValueError("Signing unexpectedly modified the feed payload")
    envelope = canonical(dict(payload=base64.b64encode(payload).decode(), signature=signature))
    if len(envelope) > 1048576:
        raise ValueError("Server feed exceeds the supported size; do not silently drop older clients")
    verify_envelope(envelope, directory)
    return envelope


def validated(directory, version, build, arch, key):
    manifest = json.loads((directory / "app-managed.json").read_text())
    return validate_completed(directory, version, build, arch, manifest["protocolVersion"], key)


def publish_release(directory, manifest, channel):
    binary = directory / "tilrd"
    with tempfile.TemporaryDirectory(prefix="publish-", dir=directory) as temp:
        temp = Path(temp)
        url = feed_url(manifest["arch"], channel)
        previous_path = temp / "previous.json"
        previous = verify_envelope(previous_path.read_bytes(), temp) if fetch(url, previous_path) else None
        feed = next_feed(previous, manifest, binary.stat().st_size, channel)
        envelope = signed_feed(feed, temp)
        artifact_url = release_url(manifest)
        remote = temp / "remote-server"
        def put(url, path, cache):
            key = url.removeprefix(CDN + "/")
            if key == url:
                raise ValueError("Refusing a publication outside the configured CDN")
            put_object(path, key, "application/json" if path.suffix == ".json" else "application/octet-stream", cache)
        # Never overwrite an immutable artifact with a different release, across either channel.
        if fetch(artifact_url, remote):
            if digest(remote) != manifest["sha256"]:
                raise ValueError("Immutable server URL already contains different bytes")
        else:
            put(artifact_url, binary, "public, max-age=31536000, immutable")
            if not fetch(artifact_url, remote) or digest(remote) != manifest["sha256"]:
                raise ValueError("Public server download not verified; feed was not changed. Retry publish-only later.")
        if previous != feed:
            # Detect an externally changed feed before replacing it. Publish from one runner.
            current = temp / "current.json"
            found = fetch(url, current)
            if found != previous_path.exists() or (found and current.read_bytes() != previous_path.read_bytes()):
                raise ValueError("Server feed changed during publication; retry from the new feed")
            file = temp / "feed.json"
            file.write_bytes(envelope)
            put(url, file, "no-cache")
        check = temp / "published.json"
        if not fetch(url, check) or verify_envelope(check.read_bytes(), temp) != feed:
            raise ValueError("Published server feed not verified; retry publish-only")
        (directory / f"published-{channel}.json").write_text(json.dumps(dict(feed=url, download=artifact_url), indent=2) + "\n")
        success(f"Published server only: {artifact_url}")


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int, help="Server release number, independent of app build numbers")
    parser.add_argument("--arch", choices=tuple(TARGETS), action="append", help="Default: acquire/publish both architectures")
    parser.add_argument("--channel", choices=("stable", "beta"), default="stable")
    parser.add_argument("--min-app-build", type=int, default=1)
    parser.add_argument("--max-app-build", type=int)
    parser.add_argument("--publish-only", action="store_true")
    parser.add_argument("--protocol-version", type=int, help="Protocol declared by the pinned upstream release")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or args.build < 1:
        parser.error("Use a numeric version and positive server build")
    if args.min_app_build < 1 or (args.max_app_build is not None and args.max_app_build < args.min_app_build):
        parser.error("Invalid compatible app build range")
    if not args.publish_only and (args.protocol_version is None or not 0 < args.protocol_version <= 4294967295):
        parser.error("Acquisition requires a positive u32 --protocol-version")
    arches = list(dict.fromkeys(args.arch or TARGETS))
    config = settings(require_build=False)
    (ROOT / "build").mkdir(exist_ok=True)
    with (ROOT / "build/server-release.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        outputs = [(arch, ROOT / "build/server-releases" / f"{args.version}-{args.build}-{arch}") for arch in arches]
        if args.publish_only:
            key = sparkle_public_key(TOOLS)
            if key != config["TILR_UPDATE_PUBLIC_KEY"]:
                raise ValueError("Configured server signing key differs from the release key")
            # Validate all local artifacts before exposing any architecture.
            manifests = [validated(path, args.version, args.build, arch, key) for arch, path in outputs]
            for (_, path), manifest in zip(outputs, manifests):
                publish_release(path, manifest, args.channel)
        else:
            for arch, path in outputs:
                acquire(path, arch, args.version, args.build, args.protocol_version,
                        config.get("TILR_UPDATE_PUBLIC_KEY", ""), args.min_app_build, args.max_app_build)
                success(f"Server artifact ready: {path}")
            print("Nothing published. Test these artifacts, then run the same version/build with --publish-only.")



if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        failure(f"Server release stopped: {error}")
        raise SystemExit(1)
