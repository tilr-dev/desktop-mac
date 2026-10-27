#!/usr/bin/env python3
"""CI-only app numbering and GitHub publication; local numbering stays local."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from publish import build_of, fetch, feed_items
from release_all import ARCHES, feed_for


def resolve_build(channel, requested):
    maximum = 0
    with tempfile.TemporaryDirectory() as temporary:
        for arch in ARCHES:
            path = Path(temporary) / f"{arch}.xml"
            if fetch(feed_for(arch, channel), path):
                maximum = max([maximum] + [build_of(item) for item in feed_items(path.read_bytes())])
    if requested and (not requested.isdecimal() or int(requested) < 1):
        raise ValueError("Build must be a positive integer")
    build = int(requested) if requested else maximum + 1
    if build <= maximum:
        raise ValueError(f"Build {build} must be greater than published build {maximum}")
    print(f"App build: {build} (highest published on {channel}: {maximum})", flush=True)
    return build


def publish_github(version, build, root, repository, sha, notes):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version) or build < 1:
        raise ValueError("Invalid release version or build")
    assets = [root / f"{version}-{build}-{arch}" / f"Tilr-{version}-{build}-{arch}.dmg"
              for arch in ARCHES]
    for asset in assets:
        if not asset.is_file():
            raise ValueError(f"Missing release DMG: {asset}")
    tag = f"v{version}"
    # Creating a ref fails if it exists. Never update/delete a tag or reuse one from another run.
    try:
        subprocess.run(["gh", "api", "--method", "POST", f"repos/{repository}/git/refs",
                        "-f", f"ref=refs/tags/{tag}", "-f", f"sha={sha}"], check=True)
    except subprocess.CalledProcessError as error:
        raise ValueError(f"Cannot create {tag}; it may already exist. Existing tags and releases are left unchanged.") from error
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "notes.txt"
        path.write_text(notes)
        subprocess.run(["gh", "release", "create", tag, "--repo", repository, "--verify-tag",
                        "--title", f"Tilr {version} ({build})", "--notes-file", str(path),
                        *map(str, assets)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    numbering = commands.add_parser("build")
    numbering.add_argument("--channel", choices=("stable", "beta"), required=True)
    numbering.add_argument("--build", default="")
    github = commands.add_parser("github")
    github.add_argument("--version", required=True)
    github.add_argument("--build", type=int, required=True)
    github.add_argument("--root", type=Path, default=Path("build/releases"))
    args = parser.parse_args()
    if args.command == "build":
        build = resolve_build(args.channel, args.build)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"build={build}\n")
    else:
        publish_github(args.version, args.build, args.root, os.environ["GITHUB_REPOSITORY"],
                       os.environ["GITHUB_SHA"], os.environ.get("NOTES", ""))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
