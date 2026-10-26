#!/usr/bin/env python3
"""Independent macOS server release: build/notarize, then publish the tested artifacts.

App releases only copy the server artifact pinned in ../server-release.json.
Server publication never rebuilds or publishes the Mac application/Sparkle feed.
"""
from release_console import ArgumentParser, success, failure
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from bundle_server import ROOT, TARGETS, TILRD, build_server, digest
from publish import ACCOUNT, BUCKET, CDN, fetch, run, sparkle_key, sparkle_public_key
from release import sign
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


def build_release(directory, arch, version, build, config, preview, min_app_build, max_app_build, source=TILRD):
    directory.mkdir(parents=True, exist_ok=False)
    manifest = build_server(directory, arch, version, build,
                            lambda binary: sign(binary, "-" if preview else config["TILR_SIGN_IDENTITY"]),
                            min_app_build, max_app_build, core=source)
    run("codesign", "--verify", "--strict", directory / "tilrd")
    if not preview:
        archive = directory / "notarization.zip"
        run("ditto", "-c", "-k", directory / "tilrd", archive)
        response = subprocess.check_output(["xcrun", "notarytool", "submit", str(archive), "--keychain-profile",
                                            config["TILR_NOTARY_PROFILE"], "--wait", "--output-format", "json"], text=True)
        notarization = json.loads(response)
        (directory / "notarization.json").write_text(response)
        if notarization.get("status") != "Accepted":
            raise ValueError("Apple did not accept the server notarization; nothing can be published")
        archive.unlink()
    (directory / "sizes.json").write_text(json.dumps(dict(
        architecture=arch, binary_bytes=(directory / "tilrd").stat().st_size,
        unstripped_bytes=(directory / "symbols/tilrd.unstripped").stat().st_size), indent=2) + "\n")
    receipt = dict(preview=preview, manifest=manifest, public_key=config.get("TILR_UPDATE_PUBLIC_KEY", ""))
    (directory / "release.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return manifest


def validated(directory, version, build, arch, key):
    receipt = json.loads((directory / "release.json").read_text())
    manifest = json.loads((directory / "app-managed.json").read_text())
    if receipt.get("preview") is not False or receipt.get("public_key") != key or receipt.get("manifest") != manifest:
        raise ValueError("Only the completed signed server release can be published")
    if any(manifest.get(k) != v for k, v in dict(version=version, build=build, arch=arch).items()):
        raise ValueError("Server release differs from the requested version/build/architecture")
    if digest(directory / "tilrd") != manifest["sha256"]:
        raise ValueError("Server changed after release completion")
    run("codesign", "--verify", "--strict", directory / "tilrd")
    return manifest


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
        env = dict(os.environ, CLOUDFLARE_ACCOUNT_ID=ACCOUNT)
        def put(url, path, cache):
            key = url.removeprefix(CDN + "/")
            if key == url:
                raise ValueError("Refusing a publication outside the configured CDN")
            run("wrangler", "r2", "object", "put", f"{BUCKET}/{key}", "--file", path,
                "--content-type", "application/json" if path.suffix == ".json" else "application/octet-stream",
                "--cache-control", cache, "--remote", env=env)
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
    parser.add_argument("--arch", choices=tuple(TARGETS), action="append", help="Default: build/publish both architectures")
    parser.add_argument("--channel", choices=("stable", "beta"), default="stable")
    parser.add_argument("--min-app-build", type=int, default=1)
    parser.add_argument("--max-app-build", type=int)
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--publish-only", action="store_true")
    parser.add_argument("--source", type=Path, default=TILRD, help="Explicit tilrd source checkout")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", args.version) or args.build < 1:
        parser.error("Use a numeric version and positive server build")
    if args.min_app_build < 1 or (args.max_app_build is not None and args.max_app_build < args.min_app_build):
        parser.error("Invalid compatible app build range")
    if args.preview and args.publish_only:
        parser.error("Preview servers cannot be published")
    arches = list(dict.fromkeys(args.arch or TARGETS))
    config = {} if args.preview else settings(require_build=not args.publish_only)
    (ROOT / "build").mkdir(exist_ok=True)
    with (ROOT / "build/server-release.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        outputs = [(arch, ROOT / "build/server-releases" / f"{args.version}-{args.build}-{arch}{'-preview' if args.preview else ''}") for arch in arches]
        if args.publish_only:
            key = sparkle_public_key(TOOLS)
            if key != config["TILR_UPDATE_PUBLIC_KEY"]:
                raise ValueError("Configured server signing key differs from the release key")
            # Validate all local artifacts before exposing any architecture.
            manifests = [validated(path, args.version, args.build, arch, key) for arch, path in outputs]
            for (_, path), manifest in zip(outputs, manifests):
                publish_release(path, manifest, args.channel)
        else:
            installed = subprocess.check_output(["rustup", "target", "list", "--installed"], text=True).split()
            missing = [TARGETS[a] for a in arches if TARGETS[a] not in installed]
            if missing:
                raise ValueError("Run on the build machine: rustup target add " + " ".join(missing))
            for arch, path in outputs:
                build_release(path, arch, args.version, args.build, config, args.preview, args.min_app_build, args.max_app_build, args.source.resolve())
                success(f"Server artifact ready: {path}")
            if args.preview:
                print("Local preview only; it cannot be published. Build again without --preview for a public release.")
            else:
                print("Nothing published. Test these artifacts, then run the same version/build with --publish-only.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        failure(f"Server release stopped: {error}")
        raise SystemExit(1)
