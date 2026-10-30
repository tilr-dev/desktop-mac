#!/usr/bin/env python3
"""Install the plugin manager (gitpm's XCFramework and Swift API) from the gitpm release in gitpm.pin."""
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile

from bundle_server import ROOT, digest
from publish import fetch
from release_console import ArgumentParser, success, failure

REPOSITORY = "https://github.com/tilr-dev/gitpm"
ARCHES = ("arm64", "x86_64")
LIBRARY = "libgitpm_ffi.a"


def read_pin(path):
    """gitpm.pin: one line `<tag> <commit> <archive sha256>`; # starts a comment line."""
    lines = [line.split() for line in path.read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if (len(lines) != 1 or len(lines[0]) != 3
            or not re.fullmatch(r"v\d+\.\d+\.\d+(-rc\.\d+)?", lines[0][0])
            or not re.fullmatch(r"[0-9a-f]{40}", lines[0][1])
            or not re.fullmatch(r"[0-9a-f]{64}", lines[0][2])):
        raise ValueError(f"{path.name} must hold one line `vX.Y.Z[-rc.N] <full commit> <archive sha256>`")
    return tuple(lines[0])


def archive_url(tag):
    return f"{REPOSITORY}/releases/download/{tag}/gitpm-ffi-{tag}-universal-apple-darwin.tar.gz"


def tag_commit(tag):
    """The commit a tag points to; for an annotated tag, its peeled ^{} line."""
    output = subprocess.run(["git", "ls-remote", REPOSITORY, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
                            check=True, capture_output=True, text=True).stdout
    refs = {ref: sha for sha, ref in (line.split("\t", 1) for line in output.splitlines() if "\t" in line)}
    commit = refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")
    if not commit:
        raise ValueError(f"gitpm has no tag {tag}")
    return commit


def stamp_text(tag, sha256):
    return f"release {tag} {sha256}\n"


def installed(root, tag, sha256):
    stamp = root / "Vendor/.gitpm-built"
    return (stamp.is_file() and stamp.read_text() == stamp_text(tag, sha256)
            and any((root / "Vendor/GitpmFFI.xcframework").rglob(LIBRARY))
            and (root / "Sources/Gitpm/Generated/Gitpm.swift").is_file())


def prepare(temp, tag, commit, sha256):
    """Download, verify and extract the pinned archive; returns the extracted top folder."""
    url = archive_url(tag)
    archive = temp / Path(url).name
    checksum = archive.with_suffix(archive.suffix + ".sha256")
    if not fetch(url, archive) or not fetch(url + ".sha256", checksum):
        raise ValueError(f"Missing gitpm release asset: {url}")
    published = re.fullmatch(r"([0-9a-fA-F]{64})  " + re.escape(archive.name) + r"\s*", checksum.read_text())
    actual = digest(archive)
    if not published or published[1].lower() != actual:
        raise ValueError("gitpm archive SHA-256 differs from the published checksum or the checksum is malformed")
    if actual != sha256:
        raise ValueError(f"gitpm archive SHA-256 {actual} differs from gitpm.pin {sha256}")
    if tag_commit(tag) != commit:
        raise ValueError(f"gitpm tag {tag} does not point to the pinned commit {commit}")
    name = archive.name.removesuffix(".tar.gz")
    out = temp / "extract"
    out.mkdir()
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if (not path.parts or path.is_absolute() or ".." in path.parts or path.parts[0] != name
                    or not (member.isfile() or member.isdir())):
                raise ValueError(f"Unsafe gitpm archive entry: {member.name}")
        tar.extractall(out, members=members, filter="data")
    top = out / name
    libraries = list((top / "GitpmFFI.xcframework").rglob(LIBRARY))
    if not (top / "GitpmFFI.xcframework/Info.plist").is_file() or len(libraries) != 1 or not (top / "swift/Gitpm.swift").is_file():
        raise ValueError("gitpm archive must contain GitpmFFI.xcframework with one static library and swift/Gitpm.swift")
    for arch in ARCHES:
        if subprocess.run(["lipo", str(libraries[0]), "-verify_arch", arch], capture_output=True).returncode != 0:
            raise ValueError(f"gitpm static library has no {arch} slice")
    return top


def install(root, top, tag, sha256):
    vendor = root / "Vendor"
    vendor.mkdir(exist_ok=True)
    stamp = vendor / ".gitpm-built"
    stamp.unlink(missing_ok=True)  # an interrupted install is never taken for the pinned release
    xcf = vendor / "GitpmFFI.xcframework"
    shutil.rmtree(xcf, ignore_errors=True)
    shutil.copytree(top / "GitpmFFI.xcframework", xcf)
    swift = root / "Sources/Gitpm/Generated/Gitpm.swift"
    swift.parent.mkdir(parents=True, exist_ok=True)
    # Rewritten only on change, so an unchanged API does not recompile the Swift target.
    if not swift.is_file() or swift.read_bytes() != (top / "swift/Gitpm.swift").read_bytes():
        shutil.copyfile(top / "swift/Gitpm.swift", swift)
    stamp.write_text(stamp_text(tag, sha256))


def main():
    parser = ArgumentParser(description=__doc__)
    parser.parse_args()
    tag, commit, sha256 = read_pin(ROOT / "gitpm.pin")
    if installed(ROOT, tag, sha256):
        success(f"gitpm {tag} already installed")
        return 0
    with tempfile.TemporaryDirectory(prefix="fetch-gitpm-") as temp:
        # Everything is verified before Vendor/ changes.
        top = prepare(Path(temp), tag, commit, sha256)
        install(ROOT, top, tag, sha256)
    success(f"Installed gitpm {tag} ({commit[:12]}) into Vendor/")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        failure(f"gitpm fetch stopped: {error}")
        raise SystemExit(1)
