#!/usr/bin/env python3
"""CI-only app numbering and GitHub publication; local numbering stays local."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from publish import build_of, fetch, feed_items
from release_all import ARCHES, feed_for


def resolve_build(requested):
    maximum = 0
    with tempfile.TemporaryDirectory() as temporary:
        for channel in ("stable", "beta"):
            for arch in ARCHES:
                path = Path(temporary) / f"{channel}-{arch}.xml"
                if fetch(feed_for(arch, channel), path):
                    maximum = max([maximum] + [build_of(item) for item in feed_items(path.read_bytes())])
    if requested and (not requested.isdecimal() or int(requested) < 1):
        raise ValueError("Build must be a positive integer")
    build = int(requested) if requested else maximum + 1
    if build <= maximum:
        raise ValueError(f"Build {build} must be greater than published build {maximum}")
    print(f"App build: {build} (highest published across stable and beta: {maximum})", flush=True)
    return build


def candidate(tag, repository, sha):
    match = re.fullmatch(r"v([0-9]+(?:\.[0-9]+){2})-rc\.([1-9][0-9]*)", tag)
    if not match:
        raise ValueError("Expected a candidate tag vX.Y.Z-rc.N")
    ref = json.loads(subprocess.check_output(
        ["gh", "api", f"repos/{repository}/git/ref/tags/{tag}"], text=True))
    if ref["object"]["type"] != "commit" or ref["object"]["sha"] != sha:
        raise ValueError(f"Candidate tag {tag} does not point to workflow commit {sha}")
    release = json.loads(subprocess.check_output(
        ["gh", "release", "view", tag, "--repo", repository, "--json", "isPrerelease,isDraft,body,assets"], text=True))
    if not release["isPrerelease"] or release["isDraft"]:
        raise ValueError(f"{tag} must be a published prerelease")
    if release["assets"]:
        raise ValueError(f"{tag} already has assets; existing releases are left unchanged")
    return match[1], release["body"]


def publish_github(tag, build, root, repository, sha):
    version, _ = candidate(tag, repository, sha)
    if build < 1:
        raise ValueError("Build must be a positive integer")
    assets = [root / f"{version}-{build}-{arch}" / f"Tilr-{version}-{build}-{arch}.dmg"
              for arch in ARCHES]
    for asset in assets:
        if not asset.is_file():
            raise ValueError(f"Missing release DMG: {asset}")
    # The shared workflow owns the immutable tag and prerelease. Never recreate either,
    # or use --clobber: a rerun must not replace artifacts from a previous publication.
    subprocess.run(["gh", "release", "upload", tag, "--repo", repository, *map(str, assets)], check=True)
    subprocess.run(["gh", "release", "edit", tag, "--repo", repository,
                    "--title", f"Tilr {tag[1:]} ({build})"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    numbering = commands.add_parser("build")
    numbering.add_argument("--build", default="")
    metadata = commands.add_parser("candidate")
    metadata.add_argument("--tag", required=True)
    metadata.add_argument("--notes-file", type=Path, required=True)
    github = commands.add_parser("github")
    github.add_argument("--tag", required=True)
    github.add_argument("--build", type=int, required=True)
    github.add_argument("--root", type=Path, default=Path("build/releases"))
    args = parser.parse_args()
    if args.command == "build":
        build = resolve_build(args.build)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"build={build}\n")
    elif args.command == "candidate":
        version, notes = candidate(args.tag, os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"])
        args.notes_file.write_text(notes)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"version={version}\n")
    else:
        publish_github(args.tag, args.build, args.root, os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
