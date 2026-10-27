#!/usr/bin/env python3
"""Prepare a signed Sparkle feed; --publish uploads verified assets, then the feed."""
from release_console import ArgumentParser, success, failure
import base64
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
CDN = "https://cdn.tilr.dev"
BUCKET = "tilr-cdn"
ACCOUNT = "8e0530af975a33f2f739127f75084531"
ENDPOINT = f"https://{ACCOUNT}.r2.cloudflarestorage.com"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE}


def run(*args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def sparkle_key():
    """Sparkle tool arguments: the Keychain account, or TILR_SPARKLE_KEY_FILE on an unattended runner."""
    path = os.environ.get("TILR_SPARKLE_KEY_FILE")
    return ["--ed-key-file", path] if path else ["--account", "tilr-rexuni"]


def sparkle_public_key(tools):
    path = os.environ.get("TILR_SPARKLE_KEY_FILE")
    if path:
        # generate_keys reads only the Keychain; CryptoKit derives the key file's public half.
        return subprocess.check_output(["swift", str(ROOT / "scripts/sparkle_public_key.swift"), path], text=True).strip()
    return subprocess.check_output([str(tools / "generate_keys"), "--account", "tilr-rexuni", "-p"], text=True).strip()


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def fetch(url, path):
    """404 means absent; auth/network/server failures must never mean a new feed."""
    result = run("curl", "-sS", "-L", "--proto", "=https", "--proto-redir", "=https",
                 "--connect-timeout", "15", "--max-time", "300",
                 "-H", "Cache-Control: no-cache", "-o", path, "-w", "%{http_code}", url,
                 capture_output=True, text=True)
    status = result.stdout.strip()
    if status == "404":
        print(f"HTTP 404: {url}", flush=True)
        path.unlink(missing_ok=True)
        return False
    if status != "200":
        raise ValueError(f"HTTP {status} reading {url}; refusing to publish")
    return True


def feed_items(data):
    root = ET.fromstring(data)
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Expected a Sparkle RSS feed")
    return root.findall("channel/item")


def build_of(item):
    value = item.findtext("sparkle:version", namespaces=NS)
    if value is None:
        enclosure = item.find("enclosure")
        value = enclosure.get(f"{{{SPARKLE}}}version") if enclosure is not None else None
    if not value or not value.isdecimal():
        raise ValueError("Feed contains a missing/non-integer build number")
    return int(value)


def check_newer(data, build):
    if data is not None and any(build_of(item) >= build for item in feed_items(data)):
        raise ValueError(f"Build {build} is not newer than the published feed; increase --build")


def validate_app_metadata(info, meta):
    """Accept runtime routing or unchanged completed legacy channel-bound apps."""
    expected = {"CFBundleIdentifier": "dev.tilr.mac", "CFBundleVersion": str(meta["build"]),
                "CFBundleShortVersionString": meta["version"], "SUPublicEDKey": meta["public_key"]}
    if "TilrUpdateFeedSelection" in info:
        if info["TilrUpdateFeedSelection"] != "preferences" or "SUFeedURL" in info:
            raise ValueError("Invalid runtime update feed metadata")
    else:
        expected["SUFeedURL"] = meta["feed"]
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("Release metadata differs from the application bundle")


def validate_manifest(directory):
    meta = json.loads((directory / "release.json").read_text())
    if meta.get("preview") is not False:
        raise ValueError("Only completed public releases can be published")
    name = meta["dmg"]
    if Path(name).name != name or not name.endswith(".dmg") or "preview" in name:
        raise ValueError("Invalid release DMG name")
    if type(meta["build"]) is not int or meta["build"] < 1:
        raise ValueError("Invalid release build")
    if meta["arch"] not in ("arm64", "x86_64", "universal"):
        raise ValueError("Unknown architecture")
    allowed = [f"{CDN}/mac/{meta['arch']}/appcast.xml",
               f"{CDN}/mac/beta/{meta['arch']}/appcast.xml"]
    if meta["feed"] not in allowed:
        raise ValueError(f"This publisher supports only the Tilr stable/beta feed for {meta['arch']}")
    dmg = directory / name
    if digest(dmg) != meta["sha256"]:
        raise ValueError("DMG changed since successful release completion")
    with (directory / "Tilr.app/Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    validate_app_metadata(info, meta)
    from bundle_plugins import plugin_inventory
    plugins = plugin_inventory(directory / 'Tilr.app')
    if plugins or 'native_plugins' in meta:
        if meta.get('native_plugins') != plugins:
            raise ValueError('Native plugins differ from the completed release inventory')
    if meta.get("packaging") == 1:
        from release_packaging import audit
        audit(directory / "Tilr.app", meta["arch"])
    from bundle_server import verify_server
    verify_server(directory / "Tilr.app", meta["version"], meta["build"], meta["arch"])
    return meta, dmg


def validate_candidate(data, meta, dmg, require_no_skip=False):
    items = [item for item in feed_items(data) if build_of(item) == meta["build"]]
    if len(items) != 1:
        raise ValueError("Generated feed must contain exactly one item for this build")
    item = items[0]
    if require_no_skip:
        critical = item.find("sparkle:criticalUpdate", namespaces=NS)
        if critical is None or critical.attrib or item.find("sparkle:minimumAutoupdateVersion", namespaces=NS) is not None:
            raise ValueError("Generated update must disable version skipping for every installed version")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Missing update enclosure")
    expected_url = meta["feed"].rsplit("/", 1)[0] + "/" + dmg.name
    if enclosure.get("url") != expected_url or enclosure.get("length") != str(dmg.stat().st_size):
        raise ValueError("Generated update URL/size does not match the DMG")
    if item.findtext("sparkle:shortVersionString", namespaces=NS) != meta["version"]:
        raise ValueError("Generated feed marketing version differs from the release")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Missing/invalid EdDSA signature")
    return signature


def put(path, key, content_type, cache):
    # S3 object access with bucket-scoped R2 credentials (AWS_* variables or AWS_PROFILE), as in tilrd.
    run("aws", "s3", "cp", path, f"s3://{BUCKET}/{key}", "--endpoint-url", ENDPOINT, "--region", "auto",
        "--content-type", content_type, "--cache-control", cache)


def stage_delta_history(meta, previous, stage, tools, limit, releases=None):
    """Only use local archives authenticated by the already published same-track feed."""
    if not previous or not limit:
        return []
    releases = releases or ROOT / 'build/releases'
    accepted = []
    for item in sorted(feed_items(previous), key=build_of, reverse=True):
        build = build_of(item)
        if build >= meta['build'] or len(accepted) >= limit:
            continue
        enclosure = item.find('enclosure')
        if enclosure is None:
            continue
        for receipt in sorted(releases.glob('*/release.json')):
            old = json.loads(receipt.read_text())
            if (old.get('build') != build or old.get('arch') != meta['arch'] or
                old.get('feed') != meta['feed'] or old.get('public_key') != meta['public_key'] or
                old.get('preview') is not False):
                continue
            name = old['dmg']
            if Path(name).name != name or not name.endswith('.dmg'):
                raise ValueError('Invalid historical DMG name')
            archive = receipt.parent / name
            if not archive.exists():
                continue
            if digest(archive) != old['sha256']:
                raise ValueError('Historical DMG checksum mismatch')
            signature = validate_candidate(previous, old, archive)
            run(tools / 'sign_update', *sparkle_key(), '--verify', archive, signature)
            shutil.copy2(archive, stage / name)
            accepted.append(build)
            break
    return accepted


def delta_entries(data, meta):
    prefix = meta['feed'].rsplit('/', 1)[0] + '/'
    seen = set()
    entries = []
    for item in feed_items(data):
        if build_of(item) != meta['build']:
            continue
        for entry in item.findall('sparkle:deltas/enclosure', NS):
            url = entry.get('url', '')
            name = url.removeprefix(prefix)
            source = entry.get(f'{{{SPARKLE}}}deltaFrom', '')
            length = entry.get('length', '')
            signature = entry.get(f'{{{SPARKLE}}}edSignature', '')
            if (not url.startswith(prefix) or Path(name).name != name or not name.endswith('.delta')
                or '%' in name or '?' in name or '#' in name or '\\' in name
                or not source.isdecimal() or not 0 < int(source) < meta['build']
                or source in seen or not length.isdecimal() or int(length) <= 0
                or len(base64.b64decode(signature, validate=True)) != 64):
                raise ValueError('Invalid delta URL, source build, size or signature')
            seen.add(source)
            entries.append(dict(name=name, url=url, source=int(source), size=int(length), signature=signature))
    return entries


def validate_deltas(data, meta, stage, tools, allowed):
    entries = delta_entries(data, meta)
    for entry in entries:
        path = stage / entry['name']
        if entry['source'] not in allowed or path.is_symlink() or path.stat().st_size != entry['size']:
            raise ValueError('Delta differs from the verified release history or declared size')
        run(tools / 'sign_update', *sparkle_key(), '--verify', path, entry['signature'])
    return entries


def verify_remote_deltas(data, meta, stage, tools):
    for index, entry in enumerate(delta_entries(data, meta)):
        remote = stage / f'verify-delta-{index}'
        if not fetch(entry['url'], remote) or remote.stat().st_size != entry['size']:
            raise ValueError('Published delta is missing or has a different size')
        run(tools / 'sign_update', *sparkle_key(), '--verify', remote, entry['signature'])


def upload_deltas(meta, data, stage):
    for entry in delta_entries(data, meta):
        path = stage / entry['name']
        expected = digest(path)
        remote = stage / 'downloaded.delta'
        if fetch(entry['url'] + '?tilr-release-probe=' + uuid.uuid4().hex, remote):
            if digest(remote) != expected:
                raise ValueError('Immutable delta already exists with different bytes')
        else:
            key = urlsplit(entry['url']).path.lstrip('/')
            put(path, key, 'application/octet-stream', 'public, max-age=31536000, immutable')
        if not fetch(entry['url'], remote) or digest(remote) != expected:
            raise ValueError('Public delta not verified; feed was NOT updated. Retry publish-only.')


def upload_verified_assets(meta, dmg, feed, stage):
    prefix = urlsplit(meta["feed"]).path.lstrip("/").rsplit("/", 1)[0] + "/"
    url = CDN + "/" + prefix + dmg.name
    remote = stage / "downloaded.dmg"
    # Probe a unique cache key: a 404 before upload must not poison the URL Sparkle uses.
    probe = url + "?tilr-release-probe=" + uuid.uuid4().hex
    if fetch(probe, remote):
        if digest(remote) != meta["sha256"]:
            raise ValueError("An immutable DMG already exists with different bytes; use a new build")
    else:
        put(dmg, prefix + dmg.name, "application/x-apple-diskimage", "public, max-age=31536000, immutable")
    # Check the actual URL even when the object already existed. A prior failed run or
    # another client can have cached a 404; Cloudflare's default negative TTL is 180s.
    delays = (5, 15, 30, 60, 60, 30)
    for attempt in range(len(delays) + 1):
        if fetch(url, remote):
            actual = digest(remote)
            if actual != meta["sha256"]:
                raise ValueError(f"Published DMG checksum mismatch at {url}: expected {meta['sha256']}, got {actual} ({remote.stat().st_size} bytes); feed was NOT updated")
            break
        if attempt == len(delays):
            raise ValueError(f"R2 object prepared but public URL still returns HTTP 404: {url}. Check cdn.tilr.dev's bucket mapping and cached 404 responses; feed was NOT updated. Retry the same publish-only command after fixing CDN delivery.")
        delay = delays[attempt]
        print(f"Waiting {delay}s for the public DMG URL (attempt {attempt + 2}/{len(delays) + 1})…", flush=True)
        time.sleep(delay)
    checksum = stage / (dmg.name + ".sha256")
    checksum.write_text(f"{meta['sha256']}  {dmg.name}\n")
    put(checksum, prefix + checksum.name, "text/plain; charset=utf-8", "public, max-age=31536000, immutable")
    upload_deltas(meta, feed.read_bytes(), stage)
    # Re-check before the visibility point. Release operators must serialize across machines.
    current = stage / "current.xml"
    check_newer(current.read_bytes() if fetch(meta["feed"], current) else None, meta["build"])
    put(feed, prefix + "appcast.xml", "application/rss+xml; charset=utf-8", "no-cache, max-age=0, must-revalidate")
    visible = stage / "visible.xml"
    if not fetch(meta["feed"], visible) or visible.read_bytes() != feed.read_bytes():
        raise ValueError("Feed uploaded but CDN response differs; check cache before retrying")
    return url


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path)
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--notes", type=Path, help="Plain-text release notes")
    parser.add_argument("--sparkle-bin", type=Path, default=ROOT / ".build/artifacts/sparkle/Sparkle/bin")
    parser.add_argument("--maximum-deltas", type=int, default=None,
                        help="Override release-packaging.json; 0 disables app delta generation")
    args = parser.parse_args()
    packaging = json.loads((ROOT / "release-packaging.json").read_text()) if (ROOT / "release-packaging.json").exists() else {}
    maximum_deltas = args.maximum_deltas if args.maximum_deltas is not None else packaging.get("maximum_deltas", 2)
    if type(maximum_deltas) is not int or maximum_deltas < 0:
        parser.error("maximum_deltas must be a non-negative integer")
    directory = args.release.resolve()
    meta, dmg = validate_manifest(directory)
    from bundle_plugins import describe_plugins
    print(f"Publishing native plugins ({meta['arch']}): {describe_plugins(meta.get('native_plugins', []))}", flush=True)
    # Covers separate publisher processes on this Mac. Do not run releases concurrently on other Macs.
    (ROOT / "build").mkdir(exist_ok=True)
    with (ROOT / "build/publish.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for path in (directory / "Tilr.app", dmg):
            run("codesign", "--verify", "--deep", "--strict", path)
            run("xcrun", "stapler", "validate", path)
        run("spctl", "--assess", "--type", "execute", directory / "Tilr.app")
        key = sparkle_public_key(args.sparkle_bin)
        if key != meta["public_key"]:
            raise ValueError("Sparkle Keychain key differs from the key embedded in this release")
        with tempfile.TemporaryDirectory(prefix="publish-", dir=ROOT / "build") as temp:
            stage = Path(temp)
            feed = stage / "appcast.xml"
            exists = fetch(meta["feed"], feed)
            if exists and any(build_of(item) == meta["build"] for item in feed_items(feed.read_bytes())):
                # Recover a partially completed two-architecture publication without
                # re-signing/replacing an already visible archive or accepting a downgrade.
                if any(build_of(item) > meta["build"] for item in feed_items(feed.read_bytes())):
                    raise ValueError("A newer build is already published")
                signature = validate_candidate(feed.read_bytes(), meta, dmg)
                run(args.sparkle_bin / "sign_update", *sparkle_key(), "--verify", dmg, signature)
                url = meta["feed"].rsplit("/", 1)[0] + "/" + dmg.name
                remote = stage / "already-published.dmg"
                if not fetch(url, remote) or digest(remote) != meta["sha256"]:
                    raise ValueError("Existing feed points to a missing/different archive")
                verify_remote_deltas(feed.read_bytes(), meta, stage, args.sparkle_bin)
                if args.publish:
                    (directory / "published.json").write_text(json.dumps({"download": url, "feed": meta["feed"], "build": meta["build"]}, indent=2) + "\n")
                success(f"Already published and verified: {url}")
                return
            previous = feed.read_bytes() if exists else None
            check_newer(previous, meta["build"])
            history = stage_delta_history(meta, previous, stage, args.sparkle_bin, maximum_deltas)
            print(f"Verified delta bases: {history}; full DMG always available.")
            shutil.copy2(dmg, stage / dmg.name)
            if args.notes:
                (stage / dmg.with_suffix(".html").name).write_text("<pre>" + html.escape(args.notes.read_text()) + "</pre>")
            run(args.sparkle_bin / "generate_appcast", *sparkle_key(),
                "--maximum-deltas", str(maximum_deltas), "--maximum-versions", "0", "--embed-release-notes",
                "--versions", str(meta["build"]),
                "--critical-update-version", "",
                "--download-url-prefix", meta["feed"].rsplit("/", 1)[0] + "/", stage)
            signature = validate_candidate(feed.read_bytes(), meta, dmg, require_no_skip=True)
            run(args.sparkle_bin / "sign_update", *sparkle_key(), "--verify", dmg, signature)
            deltas = validate_deltas(feed.read_bytes(), meta, stage, args.sparkle_bin, history)
            saved_deltas = directory / "deltas"
            saved_deltas.mkdir(exist_ok=True)
            for entry in deltas:
                target = saved_deltas / entry["name"]
                if target.exists() and digest(target) != digest(stage / entry["name"]):
                    raise ValueError("Regenerated delta differs from prepared artifact; retain original release history")
                shutil.copy2(stage / entry["name"], target)
            (directory / "delta-sizes.json").write_text(json.dumps(deltas, indent=2) + "\n")
            shutil.copy2(feed, directory / "appcast.xml")
            if not args.publish:
                print(f"Prepared {directory / 'appcast.xml'}; nothing uploaded. Add --publish to publish.")
                return
            url = upload_verified_assets(meta, dmg, feed, stage)
            (directory / "published.json").write_text(json.dumps({"download": url, "feed": meta["feed"], "build": meta["build"]}, indent=2) + "\n")
            success(f"\nPublished build {meta['build']}\nDownload: {url}\nFeed: {meta['feed']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        failure(f"Publish stopped: {error}")
        raise SystemExit(1)
