#!/usr/bin/env python3
"""Import both signed upstream macOS server architectures, and print the application pin."""
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

from release_console import ArgumentParser, failure
from bundle_server import ROOT, TARGETS
from fetch_server import validate_completed


def run(command, **kwargs):
    print("+ " + shlex.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def release_environment():
    env = dict(os.environ)
    # Homebrew first: the AWS CLI and current Apple tooling on the release Mac.
    env["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", env.get("PATH", "")])
    return env


def execute(args, root=ROOT):
    if not 0 < args.protocol_version <= 4294967295:
        raise ValueError("Protocol version must be a positive u32")
    pin = dict(version=args.version, build=args.build, protocolVersion=args.protocol_version)
    common = [sys.executable, root / "scripts/release_server.py", "--version", args.version,
              "--build", str(args.build), "--protocol-version", str(args.protocol_version)]
    if args.preview:
        print("Planned: " + shlex.join(map(str, common)))
        print("server-release.json: " + json.dumps(pin))
        return
    env = release_environment()
    run(common, env=env)
    for arch in TARGETS:
        directory = root / "build/server-releases" / f"{args.version}-{args.build}-{arch}"
        validate_completed(directory, args.version, args.build, arch, args.protocol_version)
        receipt = json.loads((directory / "release.json").read_text())
        print(f"{directory / 'release.json'}:\n{json.dumps(receipt, indent=2)}", flush=True)
    print("server-release.json: " + json.dumps(pin))


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--protocol-version", required=True, type=int)
    parser.add_argument("--preview", action="store_true", help="Show the plan without credentials, downloading or publication")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", args.version) or args.build < 1:
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
