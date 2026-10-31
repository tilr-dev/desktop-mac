#!/usr/bin/env python3
"""Build a standalone DMG; public releases require signing, notarization and Sparkle."""
from release_console import ArgumentParser, success, failure
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from release_packaging import thin_tree, strip_executable, audit, size_report

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    print("+", " ".join(str(arg) for arg in args), flush=True)
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def embed_framework(app, framework, identity="-", arch=None):
    target = app / "Contents/Frameworks/Sparkle.framework"
    target.parent.mkdir(parents=True, exist_ok=True)
    run("ditto", framework, target)
    if arch:
        thin_tree(target, arch)
    # Sign nested code from the inside out, preserving Sparkle's layout and symlinks.
    nested = [p for p in target.rglob("*") if not p.is_symlink()
              and p.suffix in (".xpc", ".app")]
    autoupdate = target / "Versions/B/Autoupdate"
    for path in ([autoupdate] if autoupdate.exists() else []) + sorted(nested, key=lambda p: len(p.parts), reverse=True) + [target]:
        sign(path, identity)


def sign(path, identity, entitlements=None):
    args = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        args += ["--options", "runtime", "--timestamp"]
    if entitlements:
        args += ["--entitlements", entitlements]
    if identity == "-":
        run(*args, path)
        return
    policy = json.loads((ROOT / "release-packaging.json").read_text())
    attempts = policy["codesign_attempts"]
    delay = policy["codesign_retry_delay_seconds"]
    if type(attempts) is not int or not 1 <= attempts <= 10:
        raise ValueError("codesign_attempts must be an integer from 1 to 10")
    if type(delay) not in (int, float) or not 0 <= delay <= 60:
        raise ValueError("codesign_retry_delay_seconds must be between 0 and 60")
    for attempt in range(1, attempts + 1):
        try:
            result = run(*args, path, stderr=subprocess.PIPE, text=True,
                         env={**os.environ, "LC_ALL": "C"})
        except subprocess.CalledProcessError as error:
            diagnostic = error.stderr or ""
            print(diagnostic, end="", file=sys.stderr, flush=True)
            # A timestamp-service failure may be transient. Keychain, identity and
            # bundle errors must fail immediately; never fall back to unsigned code.
            if "a timestamp was expected but was not found" not in diagnostic.lower() or attempt == attempts:
                raise
            print(f"Secure timestamp missing for {path}; retrying codesign in {delay:g}s "
                  f"(attempt {attempt + 1}/{attempts}).", file=sys.stderr, flush=True)
            time.sleep(delay)
        else:
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr, flush=True)
            return


def release_version(version, release_tag=None):
    value = version if release_tag is None else release_tag
    if not re.fullmatch(re.escape(version) + r"(?:-rc\.[1-9][0-9]*)?", value):
        raise ValueError("Release tag version must match the numeric version with an optional -rc.N suffix")
    return value


def app_info(template, version, build, public_key, release_tag=None):
    """Channel-neutral signed metadata; the receipt alone routes publication."""
    info = dict(template)
    info.pop("SUFeedURL", None)
    info.pop("SUPublicEDKey", None)
    info.pop("TilrUpdateFeedSelection", None)
    info.update(CFBundleShortVersionString=version, CFBundleVersion=str(build),
                TilrReleaseTag=release_version(version, release_tag))
    if public_key:
        info.update(SUPublicEDKey=public_key, TilrUpdateFeedSelection="preferences")
    return info


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--release-tag", help="Full tag version without v, including any RC suffix")
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], default="arm64")
    parser.add_argument("--preview", action="store_true", help="Ad-hoc local preview, NOT a public release")
    parser.add_argument("--skip-build", action="store_true", help="Package an already-built matching binary")
    parser.add_argument("--build-package", type=Path, default=ROOT, help="Swift package directory (default: this repo)")
    parser.add_argument("--framework", type=Path, help="Override the Sparkle.framework artifact path")
    parser.add_argument("--native-plugins", type=Path, help="Prebuilt signed bootstrap packages; default: build from native-plugins")
    parser.add_argument("--swift-disable-sandbox", action="store_true", help="For SwiftPM inside an existing sandbox")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+(\.\d+){0,2}", args.version) or args.build < 1:
        parser.error("version must be numeric (e.g. 0.1.0); build must be positive")
    args.release_tag = release_version(args.version, args.release_tag)
    def setting(name):
        return os.environ.get(name, "")
    identity = "-" if args.preview else setting("TILR_SIGN_IDENTITY")
    profile = setting("TILR_NOTARY_PROFILE")
    feed = setting("TILR_UPDATE_FEED")
    key = setting("TILR_UPDATE_PUBLIC_KEY")
    if args.preview:
        feed, key = "", ""
    if not args.preview and (not identity.startswith("Developer ID Application:") or not profile or not feed or not key):
        parser.error("Public release requires TILR_SIGN_IDENTITY (Developer ID Application), TILR_NOTARY_PROFILE, TILR_UPDATE_FEED, TILR_UPDATE_PUBLIC_KEY. See RELEASE.md.")
    if feed or key:
        try:
            assert feed.startswith("https://") and len(base64.b64decode(key, validate=True)) == 32
        except (AssertionError, ValueError):
            parser.error("Sparkle requires an HTTPS feed and a base64 32-byte Ed25519 public key")
    os.chdir(ROOT)
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(ROOT / ".build/ModuleCache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = env["CLANG_MODULE_CACHE_PATH"]
    # SwiftPM's native build database can retain commands from the previous target
    # architecture. Separate scratch roots also keep agent releases out of dev builds.
    scratch = args.build_package.resolve() / ".build" / f"release-{args.arch}"
    swift = ["swift", "build", "--package-path", str(args.build_package.resolve()),
             "--scratch-path", str(scratch), "-c", "release"]
    if args.arch != "universal":
        swift += ["--build-system", "native"]
    for arch in (["arm64", "x86_64"] if args.arch == "universal" else [args.arch]):
        swift += ["--arch", arch]
    if args.swift_disable_sandbox:
        swift += ["--disable-sandbox"]
    # The plugin manager (Rust static library, linked into the executable: nothing to bundle or
    # sign) must exist before SwiftPM reads the package; rebuilt only when its sources changed.
    pm_script = args.build_package.resolve() / "scripts/build-gitpm.sh"
    if pm_script.exists():
        run(pm_script, "--arch", *(["arm64", "--arch", "x86_64"] if args.arch == "universal" else [args.arch]))
    if not args.skip_build:
        run(*swift, env=env)
    binary_dir = Path(subprocess.check_output(swift + ["--show-bin-path"], env=env, text=True).strip())
    framework = args.framework.resolve() if args.framework else scratch / "artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    if not framework.exists():
        parser.error("Sparkle artifact missing; run swift package resolve")
    output = ROOT / "build/releases" / f"{args.version}-{args.build}-{args.arch}{'-preview' if args.preview else ''}"
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="stage-", dir=output) as staging:
        stage = Path(staging)
        app = stage / "Tilr.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        run("ditto", binary_dir / "Tilr", contents / "MacOS/Tilr")
        run("lipo", contents / "MacOS/Tilr", "-verify_arch", *(["arm64", "x86_64"] if args.arch == "universal" else [args.arch]))
        run("ditto", ROOT / "placeholder.html", contents / "Resources/placeholder.html")
        run("ditto", ROOT / "Resources/AppIcon.icns", contents / "Resources/AppIcon.icns")
        with (ROOT / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        info = app_info(info, args.version, args.build, key, args.release_tag)
        with (contents / "Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        symbols = output / "symbols"
        strip_executable(contents / "MacOS/Tilr", symbols)
        dsym = binary_dir / "Tilr.dSYM"
        if dsym.exists():
            run("ditto", dsym, symbols / dsym.name)
        embed_framework(app, framework, identity, args.arch)
        from bundle_plugins import bundle_plugins, verify_plugin_publishers, plugin_inventory, describe_plugins
        bundle_plugins(app, args.arch, identity, args.native_plugins)
        from bundle_server import bundle_server
        bundle_server(app, args.arch, info["TilrServerProtocolVersion"])
        audit(app, args.arch)
        sign(app, identity, ROOT / 'Tilr.entitlements')
        verify_plugin_publishers(app)
        plugins = plugin_inventory(app)
        print(f"Bundled native plugins ({args.arch}): {describe_plugins(plugins)}", flush=True)
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
        if not args.preview:
            upload = output / "notarization.zip"
            run("ditto", "-c", "-k", "--keepParent", app, upload)
            run("xcrun", "notarytool", "submit", upload, "--keychain-profile", profile, "--wait")
            run("xcrun", "stapler", "staple", app)
            run("xcrun", "stapler", "validate", app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
            upload.unlink()
        run("ditto", app, output / "Tilr.app")
        (stage / "Applications").symlink_to("/Applications")
        dmg = output / f"Tilr-{args.version}-{args.build}-{args.arch}{'-preview' if args.preview else ''}.dmg"
        run("hdiutil", "create", "-volname", "Tilr", "-srcfolder", stage, "-format", "UDZO", dmg)
        if not args.preview:
            sign(dmg, identity)
            run("xcrun", "notarytool", "submit", dmg, "--keychain-profile", profile, "--wait")
            run("xcrun", "stapler", "staple", dmg)
            run("xcrun", "stapler", "validate", dmg)
        run("hdiutil", "verify", dmg)
        size_report(output / "Tilr.app", dmg, args.arch, output / "sizes.json")
        checksum = subprocess.check_output(["shasum", "-a", "256", dmg.name], cwd=output, text=True)
        (output / (dmg.name + ".sha256")).write_text(checksum)
        with dmg.open("rb") as archive:
            sha256 = hashlib.file_digest(archive, "sha256").hexdigest()
        (output / "release.json").write_text(json.dumps({
            "release_tag": args.release_tag, "version": args.version, "build": args.build, "arch": args.arch, "packaging": 1,
            "preview": args.preview, "dmg": dmg.name,
            "sha256": sha256,
            "native_plugins": plugins,
            "feed": feed, "public_key": key,
        }, indent=2) + "\n")
    success(f"\n{'LOCAL PREVIEW — not notarized' if args.preview else 'SIGNED AND NOTARIZED'}: {dmg}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        failure(f"Release stopped: {error}")
        raise SystemExit(1)
