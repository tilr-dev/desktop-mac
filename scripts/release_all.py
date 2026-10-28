#!/usr/bin/env python3
"""Package both Mac architectures using explicit CI release metadata."""
from release_console import ArgumentParser, success, failure
import base64
import os
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
    result = {name: os.environ.get(name, "") for name in SETTING_NAMES}
    required = SETTING_NAMES if require_build else ("TILR_UPDATE_PUBLIC_KEY",)
    if any(not result[name] for name in required):
        raise ValueError("Missing release environment settings: TILR_SIGN_IDENTITY, TILR_NOTARY_PROFILE, TILR_UPDATE_PUBLIC_KEY")
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
            raise ValueError("Sparkle tools missing. Provision the release runner before publishing; publication does not resolve/build source dependencies.")
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


def execute(version, build, channel, config, resume=False, root=ROOT, runner=run):
    """Build and validate both architecture packages without publication."""
    outputs = []
    inventories = []
    for arch in ARCHES:
        output = root / "build/releases" / f"{version}-{build}-{arch}"
        env = os.environ.copy()
        env.update(config)
        env["TILR_UPDATE_FEED"] = feed_for(arch, channel)
        if output.exists():
            if not resume:
                raise ValueError(f"Output already exists: {output}. Use --resume for completed builds.")
        else:
            runner([sys.executable, root / "scripts/release.py", "--version", version, "--build", str(build), "--arch", arch], env=env)
        inventories.append(completed(output, version, build, arch, env["TILR_UPDATE_FEED"], config["TILR_UPDATE_PUBLIC_KEY"]))
        outputs.append(output)
    if inventories[0] != inventories[1]:
        raise ValueError("Native plugin versions/ABIs differ between architecture releases")
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


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--channel", choices=["stable", "beta"], default="stable")
    parser.add_argument("--resume", action="store_true", help="Reuse matching completed builds")
    parser.add_argument("--check", action="store_true", help="Check runner access without building a release")
    args = parser.parse_args()
    if not args.check and (not args.version or not re.fullmatch(r"\d+(\.\d+){0,2}", args.version) or not args.build or args.build < 1):
        parser.error("Provide numeric --version and positive --build, or use --check")
    config = settings()
    (ROOT / "build").mkdir(exist_ok=True)
    preflight(config, publish=False)
    if args.check:
        return
    outputs = execute(args.version, args.build, args.channel, config, resume=args.resume)
    success("Both notarized builds are ready.")
    for output in outputs:
        success(f"Output: {output}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        failure(f"Release stopped: {error}")
        raise SystemExit(1)
