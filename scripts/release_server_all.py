#!/usr/bin/env python3
"""Import both signed upstream macOS server architectures, with a publication gate."""
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

from release_console import ArgumentParser, failure
from release_server import ROOT, TARGETS, feed_url, fetch, verify_envelope
from fetch_server import validate_completed


def run(command, **kwargs):
    print("+ " + shlex.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def release_environment():
    env = dict(os.environ)
    # Homebrew first: the AWS CLI and current Apple tooling on the release Mac.
    env["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", env.get("PATH", "")])
    return env


def verify_feeds(outputs, channel):
    for arch, directory, manifest in outputs:
        url = feed_url(arch, channel)
        with tempfile.TemporaryDirectory(prefix="verify-feed-", dir=directory) as temp:
            temp = Path(temp)
            downloaded = temp / "feed.json"
            if not fetch(url, downloaded):
                raise ValueError(f"Missing public server feed: {url}")
            feed = verify_envelope(downloaded.read_bytes(), temp)
            expected = dict(schema=1, component="tilrd", arch=arch, channel=channel)
            if any(feed.get(key) != value for key, value in expected.items()) or not any(
                    entry.get("manifest") == manifest for entry in feed.get("releases", [])):
                raise ValueError(f"Public server feed does not contain the release: {url}")
        print(f"Verified {url}")


def execute(args, root=ROOT):
    if not 0 < args.protocol_version <= 4294967295:
        raise ValueError("Protocol version must be a positive u32")
    pin = dict(version=args.version, build=args.build, protocolVersion=args.protocol_version)
    common = [sys.executable, root / "scripts/release_server.py", "--version", args.version,
              "--build", str(args.build), "--min-app-build", str(args.min_app_build),
              "--protocol-version", str(args.protocol_version), "--channel", args.channel]
    preflight = [sys.executable, root / "scripts/release_all.py", "--check", "--publish-only"]
    if args.preview:
        for command in [preflight, common, common + ["--publish-only"]]:
            print("Planned: " + shlex.join(map(str, command)))
        print("Publication requires explicit 'publish' confirmation.")
        print("server-release.json: " + json.dumps(pin))
        return
    env = release_environment()
    run(preflight, env=env)
    run(common, env=env)
    outputs = []
    for arch in TARGETS:
        directory = root / "build/server-releases" / f"{args.version}-{args.build}-{arch}"
        manifest = validate_completed(directory, args.version, args.build, arch, args.protocol_version)
        if manifest.get("minAppBuild") != args.min_app_build:
            raise ValueError(f"Imported artifact does not match requested compatibility: {directory}")
        receipt = json.loads((directory / "release.json").read_text())
        print(f"{directory / 'release.json'}:\n{json.dumps(receipt, indent=2)}", flush=True)
        outputs.append((arch, directory, manifest))
    try:
        confirmed = input("Inspect/test both artifacts. Type 'publish' to publish both architectures: ") == "publish"
    except EOFError:
        confirmed = False
    if not confirmed:
        print("Publication stopped. Artifacts remain available; use release_server.py --publish-only after inspection.")
        return
    run(common + ["--publish-only"], env=env)
    verify_feeds(outputs, args.channel)
    print("server-release.json: " + json.dumps(pin))


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--min-app-build", required=True, type=int)
    parser.add_argument("--protocol-version", required=True, type=int)
    parser.add_argument("--channel", choices=("stable", "beta"), default="stable")
    parser.add_argument("--preview", action="store_true", help="Show the plan without credentials, downloading or publication")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", args.version) or min(args.build, args.min_app_build) < 1:
        parser.error("Use a numeric version and positive build numbers")
    (ROOT / "build").mkdir(exist_ok=True)
    with (ROOT / "build/server-release-all.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        execute(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        failure(f"Server release stopped: {error}")
        raise SystemExit(1)
