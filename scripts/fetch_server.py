#!/usr/bin/env python3
"""Acquire the pinned signed tilrd GitHub Release without building or signing it."""
import json
from pathlib import Path, PurePosixPath
import platform
import re
import subprocess
import tarfile
import tempfile

from bundle_server import ROOT, TARGETS, digest
from publish import fetch
from release_console import ArgumentParser, success, failure

TEAM = "V57FF3MX26"


def release_url(version, arch):
    return f"https://github.com/tilr-dev/tilrd/releases/download/v{version}/tilr-v{version}-{TARGETS[arch]}.tar.gz"


def check_signature(binary):
    requirement = (f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                   'and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    subprocess.run(["codesign", "--verify", "--strict", "-R", requirement, str(binary)], check=True)
    details = subprocess.run(["codesign", "-dv", "--verbose=2", str(binary)], check=True,
                             capture_output=True, text=True).stderr
    if (f"TeamIdentifier={TEAM}" not in details or not re.search(r"^Timestamp=", details, re.M)
            or not re.search(r"^Authority=Developer ID Application: .* \(" + TEAM + r"\)$", details, re.M)):
        raise ValueError("Server requires the expected Developer ID Application signature and timestamp")


def check_binary(binary, arch, version):
    actual = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if actual != arch:
        raise ValueError(f"Server architecture differs from {arch}: {actual}")
    check_signature(binary)
    # clap's version string is concat!(TILR_VERSION, " (", TILR_PLATFORM, ")").
    # Inspect that signed string for foreign architectures too; they cannot run on Intel.
    cpu = "aarch64" if arch == "arm64" else "x86_64"
    pattern = rb"(?<![0-9A-Za-z.-])(" + re.escape(version.encode()) + rb"-[0-9a-f]{7,40}) \(macos-" + cpu.encode() + rb"\)"
    versions = set(re.findall(pattern, binary.read_bytes()))
    if len(versions) != 1:
        raise ValueError("Server does not contain the expected upstream release version/platform")
    identity = versions.pop().decode()
    native = "arm64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
    if arch == native:
        output = subprocess.check_output([str(binary), "--version"], text=True).strip()
        if output != f"tilrd {identity} (macos-{cpu})":
            raise ValueError("Server reports an unexpected upstream version")
    return identity


def prepare(temp, arch, version, build, protocol, min_app_build, max_app_build):
    url = release_url(version, arch)
    archive = temp / Path(url).name
    checksum = archive.with_suffix(archive.suffix + ".sha256")
    if not fetch(url, archive) or not fetch(url + ".sha256", checksum):
        raise ValueError(f"Missing upstream server release asset: {url}")
    expected = re.fullmatch(r"([0-9a-fA-F]{64})  " + re.escape(archive.name) + r"\s*", checksum.read_text())
    if not expected or digest(archive) != expected[1].lower():
        raise ValueError("Upstream archive SHA-256 mismatch or malformed checksum")
    name = archive.name.removesuffix(".tar.gz")
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if not path.parts or path.is_absolute() or ".." in path.parts or path.parts[0] != name or not (member.isfile() or member.isdir()):
                raise ValueError("Unsafe upstream archive entry")
        servers = [m for m in members if m.name == f"{name}/tilrd"]
        if len(servers) != 1 or not servers[0].isfile():
            raise ValueError("Archive must contain one regular tilrd executable")
        binary = temp / f"tilrd-{arch}"
        with tar.extractfile(servers[0]) as source:
            binary.write_bytes(source.read())
    binary.chmod(0o755)
    identity = check_binary(binary, arch, version)
    manifest = dict(version=version, build=build, arch=arch, serverVersion=identity, sha256=digest(binary),
                    protocolVersion=protocol, minAppBuild=min_app_build, maxAppBuild=max_app_build)
    provenance = dict(url=url, sha256=expected[1].lower())
    return binary, manifest, provenance


def install(destination, binary, manifest, provenance, public_key):
    destination.mkdir(parents=True, exist_ok=False)
    binary.rename(destination / "tilrd")
    (destination / "app-managed.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (destination / "sizes.json").write_text(json.dumps(dict(architecture=manifest["arch"], binary_bytes=(destination / "tilrd").stat().st_size), indent=2) + "\n")
    receipt = dict(preview=False, manifest=manifest, public_key=public_key, upstream=provenance)
    (destination / "release.json").write_text(json.dumps(receipt, indent=2) + "\n")


def acquire(directory, arch, version, build, protocol, public_key="", min_app_build=1, max_app_build=None):
    if directory.exists():
        raise ValueError(f"Server artifact already exists; inspect it before retrying: {directory}")
    with tempfile.TemporaryDirectory(prefix="fetch-server-") as temp:
        install(directory, *prepare(Path(temp), arch, version, build, protocol, min_app_build, max_app_build), public_key)
    return json.loads((directory / "app-managed.json").read_text())


def validate_completed(directory, version, build, arch, protocol, public_key=None):
    receipt = json.loads((directory / "release.json").read_text())
    manifest = json.loads((directory / "app-managed.json").read_text())
    upstream = receipt.get("upstream", {})
    if (receipt.get("preview") is not False or receipt.get("manifest") != manifest
            or upstream.get("url") != release_url(version, arch)
            or not re.fullmatch(r"[0-9a-f]{64}", upstream.get("sha256", ""))):
        raise ValueError("Server is not a completed upstream release")
    expected = dict(version=version, build=build, arch=arch, protocolVersion=protocol)
    if any(manifest.get(k) != v for k, v in expected.items()) or (public_key is not None and receipt.get("public_key") != public_key):
        raise ValueError("Server differs from the requested release pin or key")
    if digest(directory / "tilrd") != manifest["sha256"]:
        raise ValueError("Server changed after acquisition")
    if check_binary(directory / "tilrd", arch, version) != manifest["serverVersion"]:
        raise ValueError("Server version differs from the completed receipt")
    return manifest


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--public-key", default="")
    parser.add_argument("--min-app-build", type=int, default=1)
    args = parser.parse_args()
    if args.min_app_build < 1:
        parser.error("Use a positive minimum app build")
    pin = json.loads((ROOT / "server-release.json").read_text())
    if not re.fullmatch(r"\d+\.\d+\.\d+", pin["version"]):
        raise ValueError("Pin must name an upstream X.Y.Z release")
    if pin["build"] < 1 or not 0 < pin["protocolVersion"] <= 4294967295:
        raise ValueError("Pin must contain positive build and protocol numbers")
    with tempfile.TemporaryDirectory(prefix="fetch-server-") as temp:
        prepared = {}
        for arch in TARGETS:
            directory = ROOT / "build/server-releases" / f"{pin['version']}-{pin['build']}-{arch}"
            if directory.exists():
                manifest = validate_completed(directory, pin["version"], pin["build"], arch, pin["protocolVersion"], args.public_key)
                if manifest["minAppBuild"] != args.min_app_build:
                    raise ValueError("Cached server has different app compatibility metadata")
            else:
                prepared[arch] = (directory, prepare(Path(temp), arch, pin["version"], pin["build"], pin["protocolVersion"], args.min_app_build, None))
        # Verify both architectures before completing either new artifact.
        for directory, payload in prepared.values():
            install(directory, *payload, args.public_key)
            success(f"Acquired upstream server: {directory}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        failure(f"Server fetch stopped: {error}")
        raise SystemExit(1)
