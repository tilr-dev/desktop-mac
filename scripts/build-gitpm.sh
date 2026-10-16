#!/bin/sh
# Make the plugin manager (gitpm, Rust, ../plugin-manager) available to SwiftPM:
#   Vendor/GitpmFFI.xcframework            static library + C module GitpmFFI (binaryTarget)
#   Sources/Gitpm/Generated/Gitpm.swift    UniFFI's Swift API (target Gitpm)
# Both are generated and gitignored. They are rebuilt (plugin-manager/scripts/build-apple.sh,
# universal arm64 + x86_64) when missing or when the SHA-256 of the library sources differs
# from the last build's (a checkout or touch alone does not rebuild); otherwise this is a no-op. run.sh and scripts/release.py call it before `swift build`.
#
#   scripts/build-gitpm.sh [--arch ARCH]... [--force]
#     --arch   a slice the library must contain (default: this Mac's); repeat for several
#     --force  rebuild even when up to date
# GITPM_DIR: the library's checkout (default ../plugin-manager).
# Needs cargo + rustup targets aarch64-apple-darwin / x86_64-apple-darwin only to rebuild.
set -eu
cd "$(dirname "$0")/.."
here=$PWD
pm=${GITPM_DIR:-"$here/../plugin-manager"}
xcf="$here/Vendor/GitpmFFI.xcframework"
swift_out="$here/Sources/Gitpm/Generated/Gitpm.swift"
stamp="$here/Vendor/.gitpm-built"
staging="$here/.build/gitpm-apple"

arches=
force=
while [ $# -gt 0 ]; do
  case $1 in
    --arch) [ $# -ge 2 ] || { echo "build-gitpm: --arch needs a value" >&2; exit 2; }
            arches="$arches $2"; shift 2 ;;
    --force) force=1; shift ;;
    *) echo "build-gitpm: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$arches" ] || arches=$(uname -m)

fail() { echo "build-gitpm: $*" >&2; exit 1; }
lib() { find "$xcf" -name 'libgitpm_ffi.a' 2>/dev/null | head -1; }

present=
[ -d "$xcf" ] && [ -f "$swift_out" ] && [ -f "$stamp" ] && [ -n "$(lib)" ] && present=1

stale=
if [ ! -d "$pm/crates/gitpm-ffi" ]; then
  [ -n "$present" ] || fail "plugin-manager sources not found at $pm and no built artifacts in Vendor/; check out the library there or set GITPM_DIR"
  echo "build-gitpm: sources not found at $pm; using the existing Vendor/ build" >&2
else
  pm=$(cd "$pm" && pwd -P)
  # Content hash of everything the build reads (paths included, sorted for stability).
  digest=$( (cd "$pm" && find Cargo.toml Cargo.lock crates scripts -type f ! -path '*/target/*' | LC_ALL=C sort \
              | while IFS= read -r f; do printf '%s\n' "$f"; shasum -a 256 < "$f"; done
             shasum -a 256 < "$here/scripts/build-gitpm.sh") | shasum -a 256 | cut -d' ' -f1)
  if [ -z "$present" ] || [ -n "$force" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$digest" ]; then
    stale=1
  fi
fi

if [ -n "$stale" ]; then
  command -v cargo >/dev/null 2>&1 || fail "cargo not found; install Rust (rustup) to build $pm"
  echo "build-gitpm: building $pm"
  # From the library's folder: UniFFI's bindgen reads `cargo metadata` of the working directory.
  (cd "$pm" && scripts/build-apple.sh "$staging")
  [ -d "$staging/GitpmFFI.xcframework" ] || fail "build-apple.sh made no xcframework (xcodebuild missing?)"
  mkdir -p "$here/Vendor" "$(dirname "$swift_out")"
  rm -rf "$xcf"
  ditto "$staging/GitpmFFI.xcframework" "$xcf"
  # Rewritten only on change, so an unchanged API does not recompile the Swift target.
  cmp -s "$staging/swift/Gitpm.swift" "$swift_out" || cp "$staging/swift/Gitpm.swift" "$swift_out"
  printf '%s\n' "$digest" > "$stamp"
fi

library=$(lib)
for arch in $arches; do
  lipo "$library" -verify_arch "$arch" 2>/dev/null \
    || fail "$library has no $arch slice ($(lipo -archs "$library")); rustup target add $( [ "$arch" = arm64 ] && echo aarch64 || echo "$arch" )-apple-darwin, then rerun with --force"
done
echo "plugin manager: $xcf ($(lipo -archs "$library"))"
