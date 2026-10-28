#!/usr/bin/env python3
"""Non-interactive agent entry point: two separate Mac builds, then optional publication."""
from release_console import ArgumentParser, success, failure
import base64
import fcntl
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from publish import BUCKET, CDN, ENDPOINT, sparkle_public_key, validate_manifest
from release import ROOT, sign

ARCHES = ("arm64", "x86_64")
SETTING_NAMES = ("TILR_SIGN_IDENTITY", "TILR_NOTARY_PROFILE", "TILR_UPDATE_PUBLIC_KEY")


def feed_for(arch, channel):
    return f"{CDN}/mac/{'beta/' if channel == 'beta' else ''}{arch}/appcast.xml"


def settings(require_build=True):
    path = ROOT / "release.local.json"
    saved = json.loads(path.read_text()) if path.exists() else {}
    result = {name: os.environ.get(name, saved.get(name, "")) for name in SETTING_NAMES}
    required = SETTING_NAMES if require_build else ("TILR_UPDATE_PUBLIC_KEY",)
    if any(not result[name] for name in required):
        raise ValueError("Missing signing settings. Complete the one-time setup in RELEASE.md; no credentials are requested interactively here.")
    if require_build and not result["TILR_SIGN_IDENTITY"].startswith("Developer ID Application:"):
        raise ValueError("Use the Rexuni Developer ID Application identity")
    if len(base64.b64decode(result["TILR_UPDATE_PUBLIC_KEY"], validate=True)) != 32:
        raise ValueError("Invalid Sparkle public key")
    return result


def run(command, **kwargs):
    print("+", " ".join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, stdin=subprocess.DEVNULL, **kwargs)


def preflight(config, publish, build=True):
    required = ["codesign", "xcrun", "hdiutil"]
    if build:
        required += ["swift", "ditto", "lipo", "strip"]
    if publish:
        required += ["aws", "curl"]
    missing = [name for name in required if not shutil.which(name)]
    if missing:
        raise ValueError("Missing tools: " + ", ".join(missing))
    if build:
        identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
        if f'"{config["TILR_SIGN_IDENTITY"]}"' not in identities:
            raise ValueError("Configured Developer ID identity is unavailable to THIS process. Check the runner's login Keychain and execution permissions; do not recreate the certificate.")
        run(["xcrun", "notarytool", "history", "--keychain-profile", config["TILR_NOTARY_PROFILE"]], stdout=subprocess.DEVNULL)
    if build:
        # Both slices of the plugin manager's static library before SwiftPM reads the package
        # (its binaryTarget must exist even for `swift package resolve`).
        run([ROOT / "scripts/build-gitpm.sh", "--arch", "arm64", "--arch", "x86_64"])
    tools = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
    if not (tools / "generate_keys").exists():
        if not build:
            raise ValueError("Sparkle tools missing. Provision the release runner before publishing; publish-only does not resolve/build source dependencies.")
        run(["swift", "package", "resolve"], cwd=ROOT)
    # Only publication signs feeds: a build-only runner embeds the public key and holds no Sparkle key.
    if publish:
        key = sparkle_public_key(tools)
        if key != config["TILR_UPDATE_PUBLIC_KEY"]:
            raise ValueError("Runner's Sparkle key is missing or differs from configured public key")
    # Exercise the exact facilities which can be absent in an agent sandbox.
    if build:
        with tempfile.TemporaryDirectory(prefix="release-check-", dir=ROOT / "build") as directory:
            target = Path(directory)
            # copy2 also copies macOS flags: /usr/bin/true is SIP-restricted, so
            # copystat/chflags fails even in a normal user Terminal. Only copy bytes.
            shutil.copyfile("/usr/bin/true", target / "signing-probe")
            (target / "signing-probe").chmod(0o755)
            sign(target / "signing-probe", config["TILR_SIGN_IDENTITY"])
            run(["hdiutil", "create", "-size", "8m", "-fs", "HFS+", "-volname", "Tilr release check", target / "probe.dmg"])
    if publish:
        # Checks access to the actual bucket with the R2 credentials, not just that some are set.
        run(["aws", "s3api", "head-bucket", "--bucket", BUCKET, "--endpoint-url", ENDPOINT, "--region", "auto"])
    success("Release runner preflight passed.")


def completed(directory, version, build, arch, feed, key):
    meta, _ = validate_manifest(directory)
    expected = dict(version=version, build=build, arch=arch, feed=feed, public_key=key)
    if any(meta.get(name) != value for name, value in expected.items()):
        raise ValueError(f"Existing release does not match requested version/build/channel/key: {directory}")
    from bundle_plugins import describe_plugins
    print(f"Completed native plugins ({arch}): {describe_plugins(meta.get('native_plugins', []))}", flush=True)
    return [(p['id'], p['version'], p['abi']) for p in meta.get('native_plugins', [])]


def require_beta_publication(channel, publishing):
    if publishing and channel != "beta":
        raise ValueError("Stable publication requires the CI release from a merged release PR tag; direct stable publication is disabled")


def execute(version, build, channel, config, publish=False, resume=False, notes=None, root=ROOT, runner=run, publish_only=False):
    """Never start publishing until BOTH architecture builds have completed."""
    require_beta_publication(channel, publish or publish_only)
    outputs = []
    inventories = []
    for arch in ARCHES:
        output = root / "build/releases" / f"{version}-{build}-{arch}"
        env = os.environ.copy()
        env.update(config)
        env["TILR_UPDATE_FEED"] = feed_for(arch, channel)
        if output.exists():
            if not resume and not publish_only:
                raise ValueError(f"Output already exists: {output}. Use --resume for completed builds.")
            inventory = completed(output, version, build, arch, env["TILR_UPDATE_FEED"], config["TILR_UPDATE_PUBLIC_KEY"])
        else:
            if publish_only:
                raise ValueError(f"Missing completed release: {output}. Publish-only never builds missing artifacts.")
            runner([sys.executable, root / "scripts/release.py", "--version", version, "--build", str(build), "--arch", arch], env=env)
            inventory = completed(output, version, build, arch, env["TILR_UPDATE_FEED"], config["TILR_UPDATE_PUBLIC_KEY"])
        inventories.append(inventory)
        outputs.append(output)
    if inventories[0] != inventories[1]:
        raise ValueError('Native plugin versions/ABIs differ between architecture releases')
    if publish:
        publish_pair(outputs, notes, root, runner)
    return outputs


def publish_pair(outputs, notes=None, root=ROOT, runner=run):
    """Prepare both feeds before exposing either update; callers validate the pair."""
    for should_publish in (False, True):
        for output in outputs:
            command = [sys.executable, root / "scripts/publish.py", output]
            if notes:
                command += ["--notes", str(notes)]
            if should_publish:
                command += ["--publish"]
            runner(command)


def release_history(root):
    """Read numeric release candidates and used/reserved builds without reserving."""
    info = plistlib.loads((root / "Info.plist").read_bytes())
    # The committed template carries a dev placeholder (0.0.0-dev); only a numeric one counts.
    template = str(info["CFBundleShortVersionString"])
    versions = [template] if re.fullmatch(r"\d+(?:\.\d+){0,2}", template) else []
    builds = [int(info["CFBundleVersion"])]
    releases = root / "build/releases"
    if releases.exists():
        for path in releases.iterdir():
            match = re.fullmatch(r"(\d+(?:\.\d+){0,2})-(\d+)-(?:arm64|x86_64|universal)(?:-preview)?", path.name)
            if match:
                versions.append(match[1])
                builds.append(int(match[2]))
    state = root / "build/release-auto.json"
    if state.exists():
        saved = json.loads(state.read_text())
        versions.append(saved["version"])
        builds.append(int(saved["build"]))
    return versions, builds


def automatic_release(root=ROOT, version=None, build=None, reserve=True):
    """Reserve a fresh build under the coordinator lock, including failed attempts."""
    versions, builds = release_history(root)
    def version_key(value):
        if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
            raise ValueError(f"Invalid release version: {value}")
        return tuple((list(map(int, value.split("."))) + [0, 0])[:3])
    # Keep the marketing version; only the build increments on each run.
    if not version and not versions:
        raise ValueError("No release version yet; pass --version")
    chosen = version or max(versions, key=lambda value: (version_key(value), len(value)))
    version_key(chosen)
    next_build = max(builds) + 1
    if build is not None and build < next_build:
        raise ValueError(f"Build must be at least {next_build}; older numbers are already used or reserved")
    build = build if build is not None else next_build
    if not reserve:
        return chosen, build
    state = root / "build/release-auto.json"
    state.parent.mkdir(parents=True, exist_ok=True)
    temporary = state.with_suffix(".tmp")
    temporary.write_text(json.dumps(dict(version=chosen, build=build), indent=2) + "\n")
    temporary.replace(state)
    return chosen, build



def show_status(root=ROOT):
    info = plistlib.loads((root / "Info.plist").read_bytes())
    versions, builds = release_history(root)
    version, build = automatic_release(root, reserve=False) if versions else (None, max(builds) + 1)
    print(f"Source Info.plist: {info['CFBundleShortVersionString']}, build {info['CFBundleVersion']}")
    print(f"Current release version: {version or 'none'}; highest local/reserved build: {build - 1}")
    if version:
        print(f"Next automatic build: {version}, build {build}")
    else:
        print("No release version yet; pass --version")
    latest = root / "build/latest-app-release.json"
    if latest.exists():
        saved = json.loads(latest.read_text())
        print(f"Last completed pair: {saved['version']}, build {saved['build']}, {saved['channel']}")
    else:
        print("No completed pair recorded by release.command yet.")
    pin = json.loads((root / "server-release.json").read_text())
    print(f"Bundled server pin: {pin['version']}, build {pin['build']}, protocol {pin['protocolVersion']}")
    print("Local history only; installed app and public feeds may differ.", flush=True)


def ensure_server(root=ROOT, runner=run):
    """Acquire missing pinned upstream artifacts and validate existing completed imports."""
    from fetch_server import validate_completed
    pin = json.loads((root / "server-release.json").read_text())
    directory = Path(os.environ.get("TILR_SERVER_RELEASE_ROOT", root / "build/server-releases"))
    missing = []
    for arch in ARCHES:
        output = directory / f"{pin['version']}-{pin['build']}-{arch}"
        if not output.exists():
            missing.append(arch)
        else:
            validate_completed(output, pin["version"], pin["build"], arch, pin["protocolVersion"])
    if missing:
        if directory.resolve() != (root / "build/server-releases").resolve():
            raise ValueError("Pinned server missing from TILR_SERVER_RELEASE_ROOT; provide completed artifacts there")
        command = [sys.executable, root / "scripts/release_server.py", "--version", pin["version"], "--build", str(pin["build"]),
                   "--protocol-version", str(pin["protocolVersion"])]
        for arch in missing:
            command += ["--arch", arch]
        runner(command)


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--status", action="store_true", help="Show local versions and next build without reserving or signing")
    parser.add_argument("--latest", action="store_true", help="Publish the last successfully completed app pair")
    parser.add_argument("--auto", action="store_true", help="Build with saved signing settings and reserve the next local build number; no prompts")
    parser.add_argument("--version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--channel", choices=["stable", "beta"], default="stable")
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--publish-only", action="store_true", help="Publish existing DMGs only; NEVER build, sign with Apple, or notarize again")
    parser.add_argument("--resume", action="store_true", help="Reuse matching completed builds; verify any already-published release")
    parser.add_argument("--notes", type=Path)
    parser.add_argument("--check", action="store_true", help="Check runner access without building a release")
    args = parser.parse_args()
    if args.status:
        show_status(ROOT)
        return
    if args.latest:
        if not args.publish_only or args.version or args.build is not None or args.auto:
            parser.error("--latest requires --publish-only and no explicit version/build")
        latest = ROOT / "build/latest-app-release.json"
        if not latest.exists():
            raise ValueError("No completed app pair recorded yet. Run ./release.command first, or use ./upload.command --version VERSION --build BUILD for existing artifacts.")
        saved = json.loads(latest.read_text())
        args.version, args.build, args.channel = saved["version"], saved["build"], saved["channel"]
    if args.auto and (args.resume or args.publish or args.publish_only or args.check):
        parser.error("--auto is build-only; use explicit version/build for resume, checks or publication")
    if not args.auto and not args.check and (not args.version or not re.fullmatch(r"\d+(\.\d+){0,2}", args.version) or not args.build or args.build < 1):
        parser.error("Provide numeric --version and positive --build, or use --check")
    if args.publish_only and args.publish:
        parser.error("Choose --publish-only or --publish")
    publishing = args.publish or args.publish_only
    require_beta_publication(args.channel, publishing and not args.check)
    config = settings(require_build=not args.publish_only)
    (ROOT / "build").mkdir(exist_ok=True)
    with (ROOT / "build/release-all.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.auto:
            show_status(ROOT)
        preflight(config, publishing, build=not args.publish_only)
        if args.check:
            return
        if args.auto:
            args.version, args.build = automatic_release(ROOT, version=args.version, build=args.build)
            print(f"Building Tilr {args.version}, build {args.build}, channel {args.channel}.", flush=True)
            ensure_server()
        print(f"Selected app: {args.version}, build {args.build}, channel {args.channel}.", flush=True)
        outputs = execute(args.version, args.build, args.channel, config, publishing, args.resume,
                          args.notes.resolve() if args.notes else None, publish_only=args.publish_only)
        if publishing:
            downloads = {}
            for arch, output in zip(ARCHES, outputs):
                downloads[arch] = json.loads((output / "published.json").read_text())["download"]
            summary = ROOT / "build/releases" / f"{args.version}-{args.build}-{args.channel}-downloads.json"
            summary.write_text(json.dumps(dict(version=args.version, build=args.build, downloads=downloads), indent=2) + "\n")
            success(f"Both architectures published. Website download links: {summary}")
            for arch, url in downloads.items():
                success(f"{arch}: {url}")
        else:
            latest = ROOT / "build/latest-app-release.json"
            temporary = latest.with_suffix(".tmp")
            temporary.write_text(json.dumps(dict(version=args.version, build=args.build, channel=args.channel), indent=2) + "\n")
            temporary.replace(latest)
            success("Both notarized builds are ready. Nothing published.")
            for output in outputs:
                success(f"Output: {output}")
            if args.channel == "beta":
                print("Publish this completed pair after testing: ./upload.command")
                print(f"Or explicitly: python3 scripts/release_all.py --version {args.version} --build {args.build} --channel beta --publish-only")
            else:
                print("Stable publication requires the CI release from a merged release PR tag; direct stable publication is disabled")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        failure(f"Release stopped: {error}")
        raise SystemExit(1)
