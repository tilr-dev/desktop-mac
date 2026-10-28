#!/usr/bin/env python3
"""Acquire signed upstream server artifacts for the application bundle without publication."""
import fcntl
import re
import subprocess

from bundle_server import ROOT, TARGETS
from fetch_server import acquire
from release_console import ArgumentParser, success, failure


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int, help="Artifact revision recorded in server-release.json")
    parser.add_argument("--arch", choices=tuple(TARGETS), action="append", help="Default: acquire both architectures")
    parser.add_argument("--protocol-version", type=int, help="Protocol declared by the pinned upstream release")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or args.build < 1:
        parser.error("Use a numeric X.Y.Z version and positive server build")
    if args.protocol_version is None or not 0 < args.protocol_version <= 4294967295:
        parser.error("Acquisition requires a positive u32 --protocol-version")
    arches = list(dict.fromkeys(args.arch or TARGETS))
    (ROOT / "build").mkdir(exist_ok=True)
    with (ROOT / "build/server-release.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        outputs = [(arch, ROOT / "build/server-releases" / f"{args.version}-{args.build}-{arch}") for arch in arches]
        for arch, path in outputs:
            acquire(path, arch, args.version, args.build, args.protocol_version)
            success(f"Server artifact ready: {path}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        failure(f"Server release stopped: {error}")
        raise SystemExit(1)
