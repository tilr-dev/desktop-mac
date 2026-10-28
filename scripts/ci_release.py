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

from publish import build_of, fetch, feed_items, validate_manifest
from release_all import ARCHES, feed_for, completed, preflight, settings, publish_pair


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


def release_metadata(tag, repository, sha):
    match = re.fullmatch(r"v([0-9]+(?:\.[0-9]+){2})(?:-rc\.([1-9][0-9]*))?", tag)
    if not match:
        raise ValueError("Expected a release tag vX.Y.Z or vX.Y.Z-rc.N")
    channel = "beta" if match[2] else "stable"
    ref = json.loads(subprocess.check_output(
        ["gh", "api", f"repos/{repository}/git/ref/tags/{tag}"], text=True))
    target = ref["object"]
    seen = set()
    while target["type"] == "tag":
        if target["sha"] in seen:
            raise ValueError(f"Release tag {tag} has a cyclic tag target")
        seen.add(target["sha"])
        annotated = json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{repository}/git/tags/{target['sha']}"], text=True))
        target = annotated["object"]
    if target["type"] != "commit" or target["sha"] != sha:
        raise ValueError(f"Release tag {tag} does not point to checked-out commit {sha}")
    release = json.loads(subprocess.check_output(
        ["gh", "release", "view", tag, "--repo", repository, "--json", "isPrerelease,isDraft,body,assets"], text=True))
    if release["isPrerelease"] != (channel == "beta") or release["isDraft"]:
        raise ValueError(f"{tag} must be a published {channel} release")
    if release["assets"]:
        raise ValueError(f"{tag} already has assets; existing releases are left unchanged")
    return match[1], channel, release["body"]


def release_assets(version, build, channel, root):
    if build < 1:
        raise ValueError("Build must be a positive integer")
    assets = []
    for arch in ARCHES:
        directory = root / f"{version}-{build}-{arch}"
        meta, dmg = validate_manifest(directory)
        expected = dict(version=version, build=build, arch=arch, feed=feed_for(arch, channel))
        if any(meta.get(key) != value for key, value in expected.items()):
            raise ValueError(f"Completed release metadata does not match requested release: {directory}")
        assets.append(dmg)
    return assets


def publish_cdn(tag, build, root, repository, sha, notes_file):
    version, channel, notes = release_metadata(tag, repository, sha)
    assets = release_assets(version, build, channel, root)
    # Stable cannot be republished; beta retains verified partial-publication resume.
    if channel == "stable":
        resolve_build(str(build))
    config = settings(require_build=False)
    inventories = [completed(asset.parent, version, build, arch, feed_for(arch, channel),
                             config["TILR_UPDATE_PUBLIC_KEY"])
                   for arch, asset in zip(ARCHES, assets)]
    if inventories[0] != inventories[1]:
        raise ValueError("Native plugin versions/ABIs differ between architecture releases")
    preflight(config, publish=True, build=False)
    notes_file.write_text(notes)
    outputs = [asset.parent for asset in assets]
    publish_pair(outputs, notes=notes_file)
    downloads = {arch: json.loads((directory / "published.json").read_text())["download"]
                 for arch, directory in zip(ARCHES, outputs)}
    summary = root / f"{version}-{build}-{channel}-downloads.json"
    summary.write_text(json.dumps(dict(version=version, build=build, downloads=downloads), indent=2) + "\n")


def publish_github(tag, build, root, repository, sha):
    version, channel, _ = release_metadata(tag, repository, sha)
    assets = release_assets(version, build, channel, root)
    # The shared workflow owns the immutable tag and release. Never recreate either,
    # or use --clobber: a rerun must not replace artifacts from a previous publication.
    subprocess.run(["gh", "release", "upload", tag, "--repo", repository, *map(str, assets)], check=True)
    subprocess.run(["gh", "release", "edit", tag, "--repo", repository,
                    "--title", f"Tilr {tag[1:]} ({build})"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    numbering = commands.add_parser("build")
    numbering.add_argument("--build", default="")
    metadata = commands.add_parser("release")
    metadata.add_argument("--tag", required=True)
    metadata.add_argument("--notes-file", type=Path, required=True)
    publication = commands.add_parser("publish")
    publication.add_argument("--tag", required=True)
    publication.add_argument("--build", type=int, required=True)
    publication.add_argument("--root", type=Path, default=Path("build/releases"))
    publication.add_argument("--notes-file", type=Path, required=True)
    github = commands.add_parser("github")
    github.add_argument("--tag", required=True)
    github.add_argument("--build", type=int, required=True)
    github.add_argument("--root", type=Path, default=Path("build/releases"))
    args = parser.parse_args()
    if args.command == "build":
        build = resolve_build(args.build)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"build={build}\n")
    elif args.command == "release":
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        version, channel, notes = release_metadata(args.tag, os.environ["GITHUB_REPOSITORY"], sha)
        args.notes_file.write_text(notes)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"version={version}\nchannel={channel}\n")
    else:
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        if args.command == "publish":
            publish_cdn(args.tag, args.build, args.root, os.environ["GITHUB_REPOSITORY"], sha, args.notes_file)
        else:
            publish_github(args.tag, args.build, args.root, os.environ["GITHUB_REPOSITORY"], sha)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
