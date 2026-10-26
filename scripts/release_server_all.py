#!/usr/bin/env python3
"""Release both macOS server architectures from a tag, with a publication gate."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys
import tempfile

from release_console import ArgumentParser, failure
from release_server import ROOT, TARGETS, feed_url, fetch, verify_envelope


def run(command, **kwargs):
    print("+ " + shlex.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def git(clone, *args):
    return subprocess.check_output(["git", "-C", str(clone), *args], text=True).strip()


@contextmanager
def tagged_source(clone, tag):
    # Resolve an exact ref before peeling: rev-parse alone accepts tag~1 expressions.
    tag_object = git(clone, "show-ref", "--verify", "--hash", f"refs/tags/{tag}")
    commit = git(clone, "rev-parse", "--verify", f"{tag_object}^{{commit}}")
    with tempfile.TemporaryDirectory(prefix="tilrd-release-") as temp:
        source = Path(temp) / "source"
        run(["git", "-C", clone, "worktree", "add", "--detach", source, commit])
        try:
            yield source, commit
        finally:
            run(["git", "-C", clone, "worktree", "remove", "--force", source])


def protocol_version(source):
    text = (source / "crates/tilr-proto/src/lib.rs").read_text()
    match = re.search(r"PROTOCOL_VERSION: u32 = (\d+)", text)
    if not match or not 0 < int(match[1]) <= 4294967295:
        raise ValueError("Tagged source must declare a positive u32 PROTOCOL_VERSION")
    return int(match[1])


def release_environment():
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", env.get("PATH", "")])
    node = subprocess.check_output(["node", "--version"], env=env, text=True).strip()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", node) or int(node[1:].split(".")[0]) < 22:
        raise ValueError(f"Homebrew Node >=22 required; selected {node}")
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
    with tagged_source(args.tilrd_repo.resolve(), args.tag) as (source, commit):
        protocol = protocol_version(source)
        pin = dict(version=args.version, build=args.build, protocolVersion=protocol)
        print(f"Selected tag {args.tag}: {commit}; protocol {protocol}", flush=True)
        common = [sys.executable, root / "scripts/release_server.py", "--version", args.version,
                  "--build", str(args.build), "--min-app-build", str(args.min_app_build),
                  "--channel", args.channel, "--source", source]
        preflight = [sys.executable, root / "scripts/release_all.py", "--check", "--publish"]
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
            receipt = json.loads((directory / "release.json").read_text())
            manifest = receipt["manifest"]
            expected = dict(version=args.version, build=args.build, arch=arch, protocolVersion=protocol,
                            minAppBuild=args.min_app_build,
                            serverVersion=f"{args.version}-build{args.build}-{git(source, 'rev-parse', '--short', 'HEAD')}")
            if receipt.get("preview") is not False or any(manifest.get(k) != v for k, v in expected.items()):
                raise ValueError(f"Built artifact does not match tagged release: {directory}")
            print(f"{directory / 'release.json'}:\n{json.dumps(receipt, indent=2)}", flush=True)
            outputs.append((arch, directory, manifest))
        native = "arm64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
        binary = next(directory / "tilrd" for arch, directory, _ in outputs if arch == native)
        run([binary, "--version"], env=env)
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
    parser.add_argument("--tag", required=True, help="Existing local tilrd tag")
    parser.add_argument("--tilrd-repo", type=Path, default=Path.home() / "projects/tilr/git/tilrd")
    parser.add_argument("--channel", choices=("stable", "beta"), default="stable")
    parser.add_argument("--preview", action="store_true", help="Show the plan without credentials, building or publication")
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
