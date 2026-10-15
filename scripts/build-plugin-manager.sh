#!/bin/sh
# Make the plugin manager (Rust, ../../plugin-manager) available to SwiftPM:
#   Vendor/TilrPluginManagerFFI.xcframework                         static library + C module (binaryTarget)
#   Sources/TilrPluginManager/Generated/tilr_plugin_manager_ffi.swift  UniFFI's Swift API
# Both are generated and gitignored. They are rebuilt (plugin-manager/scripts/build-apple.sh,
# universal arm64 + x86_64) when missing or when the SHA-256 of the library sources differs
# from the last build's (a checkout or touch alone does not rebuild); otherwise this is a no-op. run.sh and scripts/release.py call it before `swift build`.
#
#   scripts/build-plugin-manager.sh [--arch ARCH]... [--force]
#     --arch   a slice the library must contain (default: this Mac's); repeat for several
#     --force  rebuild even when up to date
# TILR_PLUGIN_MANAGER_DIR: the library's checkout (default ../../plugin-manager).
# Needs cargo + rustup targets aarch64-apple-darwin / x86_64-apple-darwin only to rebuild.
set -eu
cd "$(dirname "$0")/.."
here=$PWD
pm=${TILR_PLUGIN_MANAGER_DIR:-"$here/../../plugin-manager"}
xcf="$here/Vendor/TilrPluginManagerFFI.xcframework"
swift_out="$here/Sources/TilrPluginManager/Generated/tilr_plugin_manager_ffi.swift"
stamp="$here/Vendor/.plugin-manager-built"
staging="$here/.build/plugin-manager-apple"

arches=
force=
while [ $# -gt 0 ]; do
  case $1 in
    --arch) [ $# -ge 2 ] || { echo "build-plugin-manager: --arch needs a value" >&2; exit 2; }
            arches="$arches $2"; shift 2 ;;
    --force) force=1; shift ;;
    *) echo "build-plugin-manager: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$arches" ] || arches=$(uname -m)

fail() { echo "build-plugin-manager: $*" >&2; exit 1; }
lib() { find "$xcf" -name 'libtilr_plugin_manager_ffi.a' 2>/dev/null | head -1; }

present=
[ -d "$xcf" ] && [ -f "$swift_out" ] && [ -f "$stamp" ] && [ -n "$(lib)" ] && present=1

stale=
if [ ! -d "$pm/crates/tilr-plugin-manager-ffi" ]; then
  [ -n "$present" ] || fail "plugin-manager sources not found at $pm and no built artifacts in Vendor/; check out the library there or set TILR_PLUGIN_MANAGER_DIR"
  echo "build-plugin-manager: sources not found at $pm; using the existing Vendor/ build" >&2
else
  pm=$(cd "$pm" && pwd -P)
  # Content hash of everything the build reads (paths included, sorted for stability).
  digest=$( (cd "$pm" && find Cargo.toml Cargo.lock crates scripts -type f ! -path '*/target/*' | LC_ALL=C sort \
              | while IFS= read -r f; do printf '%s\n' "$f"; shasum -a 256 < "$f"; done
             shasum -a 256 < "$here/scripts/build-plugin-manager.sh") | shasum -a 256 | cut -d' ' -f1)
  if [ -z "$present" ] || [ -n "$force" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$digest" ]; then
    stale=1
  fi
fi

if [ -n "$stale" ]; then
  command -v cargo >/dev/null 2>&1 || fail "cargo not found; install Rust (rustup) to build $pm"
  echo "build-plugin-manager: building $pm"
  # From the library's folder: UniFFI's bindgen reads `cargo metadata` of the working directory.
  (cd "$pm" && scripts/build-apple.sh "$staging")
  [ -d "$staging/TilrPluginManagerFFI.xcframework" ] || fail "build-apple.sh made no xcframework (xcodebuild missing?)"
  mkdir -p "$here/Vendor" "$(dirname "$swift_out")"
  rm -rf "$xcf"
  ditto "$staging/TilrPluginManagerFFI.xcframework" "$xcf"
  # Rewritten only on change, so an unchanged API does not recompile the Swift target.
  cmp -s "$staging/swift/tilr_plugin_manager_ffi.swift" "$swift_out" || cp "$staging/swift/tilr_plugin_manager_ffi.swift" "$swift_out"
  printf '%s\n' "$digest" > "$stamp"
fi

library=$(lib)
for arch in $arches; do
  lipo "$library" -verify_arch "$arch" 2>/dev/null \
    || fail "$library has no $arch slice ($(lipo -archs "$library")); rustup target add $( [ "$arch" = arm64 ] && echo aarch64 || echo "$arch" )-apple-darwin, then rerun with --force"
done
echo "plugin manager: $xcf ($(lipo -archs "$library"))"
