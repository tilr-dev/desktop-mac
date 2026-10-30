#!/usr/bin/env python3
"""Acquire the latest stable signed tilrd GitHub Release without building or signing it."""
import json
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

from bundle_server import ROOT, TARGETS, digest
from publish import fetch
from release_console import ArgumentParser, success, failure

TEAM = "V57FF3MX26"
LATEST_URL = "https://api.github.com/repos/tilr-dev/tilrd/releases/latest"


def protocol_url(version):
    return f"https://raw.githubusercontent.com/tilr-dev/tilrd/v{version}/crates/tilr-proto/src/lib.rs"


def release_url(version, arch):
    return f"https://github.com/tilr-dev/tilrd/releases/download/v{version}/tilr-v{version}-{TARGETS[arch]}.tar.gz"


def check_signature(binary):
    requirement = (f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
                   'and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    subprocess.run(["codesign", "--verify", "--strict", f"-R={requirement}", str(binary)], check=True)
    details = subprocess.run(["codesign", "-dv", "--verbose=2", str(binary)], check=True,
                             capture_output=True, text=True).stderr
    if (f"TeamIdentifier={TEAM}" not in details or not re.search(r"^Timestamp=", details, re.M)
            or not re.search(r"^Authority=Developer ID Application: .* \(" + TEAM + r"\)$", details, re.M)):
        raise ValueError("Server requires the expected Developer ID Application signature and timestamp")


def check_binary(binary, arch, version, executable="tilrd"):
    """Verify one signed upstream executable; version None accepts any single release."""
    actual = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if actual != arch:
        raise ValueError(f"Server architecture differs from {arch}: {actual}")
    check_signature(binary)
    # clap's version string is concat!(TILR_VERSION, " (", TILR_PLATFORM, ")").
    # Inspect that signed string for foreign architectures too; they cannot run on Intel.
    cpu = "aarch64" if arch == "arm64" else "x86_64"
    # Rust can concatenate adjacent literals, so parse full release numbers first.
    pattern = rb"([0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{7,40}) \(macos-" + cpu.encode() + rb"\)"
    versions = set(re.findall(pattern, binary.read_bytes()))
    if len(versions) != 1 or (version is not None and not next(iter(versions)).startswith(version.encode() + b"-")):
        raise ValueError("Server does not contain the expected upstream release version/platform")
    identity = versions.pop().decode()
    native = "arm64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
    if arch == native:
        output = subprocess.check_output([str(binary), "--version"], text=True).strip()
        if output != f"{executable} {identity} (macos-{cpu})":
            raise ValueError("Server reports an unexpected upstream version")
    return identity


def latest_release(temp):
    """GitHub's latest release is the newest stable one; candidates are prereleases."""
    latest = temp / "latest.json"
    if not fetch(LATEST_URL, latest):
        raise ValueError("No stable tilrd GitHub Release")
    tag = json.loads(latest.read_text()).get("tag_name", "")
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)", tag if isinstance(tag, str) else "")
    if not match:
        raise ValueError(f"Latest tilrd GitHub Release is not a stable vX.Y.Z tag: {tag!r}")
    version = match[1]
    source = temp / "tilr-proto.rs"
    if not fetch(protocol_url(version), source):
        raise ValueError(f"Missing released tilrd protocol source: {protocol_url(version)}")
    values = re.findall(r"^pub const PROTOCOL_VERSION: u32 = ([0-9]+);$", source.read_text(), re.M)
    if len(values) != 1 or not 0 < int(values[0]) <= 4294967295:
        raise ValueError(f"Missing or invalid PROTOCOL_VERSION in tilrd {version}")
    return version, int(values[0])


def prepare(temp, arch, version, protocol):
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
        binaries = {}
        for executable in ("tilrd", "tilr"):
            entries = [m for m in members if m.name == f"{name}/{executable}"]
            if len(entries) != 1 or not entries[0].isfile():
                raise ValueError(f"Archive must contain one regular {executable} executable")
            binary = temp / f"{executable}-{arch}"
            with tar.extractfile(entries[0]) as source:
                binary.write_bytes(source.read())
            binary.chmod(0o755)
            binaries[executable] = binary
    identity = check_binary(binaries["tilrd"], arch, version)
    client_identity = check_binary(binaries["tilr"], arch, version, "tilr")
    if client_identity != identity:
        raise ValueError("Client and server upstream versions differ")
    binary = binaries["tilrd"]
    manifest = dict(version=version, arch=arch, serverVersion=identity, sha256=digest(binary), protocolVersion=protocol)
    provenance = dict(url=url, sha256=expected[1].lower())
    return binaries, manifest, provenance


def install(destination, binaries, manifest, provenance, public_key):
    destination.mkdir(parents=True, exist_ok=False)
    for executable, binary in binaries.items():
        shutil.copy2(binary, destination / executable)
    client = dict(version=manifest["serverVersion"], sha256=digest(destination / "tilr"))
    (destination / "client.json").write_text(json.dumps(client, indent=2) + "\n")
    (destination / "server.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (destination / "sizes.json").write_text(json.dumps(dict(architecture=manifest["arch"], binary_bytes=(destination / "tilrd").stat().st_size), indent=2) + "\n")
    receipt = dict(preview=False, manifest=manifest, public_key=public_key, upstream=provenance, client=client)
    (destination / "release.json").write_text(json.dumps(receipt, indent=2) + "\n")


def validate_completed(directory, version, arch, protocol, public_key=None):
    receipt = json.loads((directory / "release.json").read_text())
    manifest = json.loads((directory / "server.json").read_text())
    upstream = receipt.get("upstream", {})
    if (receipt.get("preview") is not False or receipt.get("manifest") != manifest
            or upstream.get("url") != release_url(version, arch)
            or not re.fullmatch(r"[0-9a-f]{64}", upstream.get("sha256", ""))):
        raise ValueError("Server is not a completed upstream release")
    expected = dict(version=version, arch=arch, protocolVersion=protocol)
    if any(manifest.get(k) != v for k, v in expected.items()) or (public_key is not None and receipt.get("public_key") != public_key):
        raise ValueError("Server differs from the selected release or key")
    if digest(directory / "tilrd") != manifest["sha256"]:
        raise ValueError("Server changed after acquisition")
    if check_binary(directory / "tilrd", arch, version) != manifest["serverVersion"]:
        raise ValueError("Server version differs from the completed receipt")
    client = json.loads((directory / "client.json").read_text())
    if (receipt.get("client") != client or client.get("version") != manifest["serverVersion"]
            or digest(directory / "tilr") != client.get("sha256")):
        raise ValueError("Client changed after acquisition")
    if check_binary(directory / "tilr", arch, version, "tilr") != client["version"]:
        raise ValueError("Client version differs from the completed receipt")
    return manifest


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--public-key", default="")
    args = parser.parse_args()
    with (ROOT / "Info.plist").open("rb") as file:
        supported = plistlib.load(file)["TilrServerProtocolVersion"]
    releases = ROOT / "build/server-releases"
    with tempfile.TemporaryDirectory(prefix="fetch-server-") as temp:
        version, protocol = latest_release(Path(temp))
        if protocol != supported:
            raise ValueError(f"Latest tilrd {version} speaks protocol {protocol}; this application supports protocol {supported}")
        prepared = {}
        for arch in TARGETS:
            directory = releases / f"{version}-{arch}"
            if directory.exists():
                validate_completed(directory, version, arch, protocol, args.public_key)
            else:
                prepared[arch] = (directory, prepare(Path(temp), arch, version, protocol))
        # Verify both architectures before completing either new artifact.
        for directory, payload in prepared.values():
            install(directory, *payload, args.public_key)
            success(f"Acquired upstream server: {directory}")
    # Bundling uses exactly this acquisition, not whatever release is latest by then.
    (releases / "selected.json").write_text(json.dumps(dict(version=version, protocolVersion=protocol), indent=2) + "\n")
    success(f"Selected tilrd {version} (protocol {protocol})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        failure(f"Server fetch stopped: {error}")
        raise SystemExit(1)
