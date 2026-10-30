# Install the plugin manager from a pinned gitpm release

## Why
CI and release builds compiled the plugin manager from an unreleased gitpm commit, so every run needed a Rust toolchain and the shipped application depended on a gitpm revision that was never released. gitpm releases and candidates now carry a universal Apple archive with the static library and its Swift bindings.

## What Changes
- `gitpm.pin` names a gitpm release tag, the commit that tag points to and the SHA-256 of the release's `gitpm-ffi-<tag>-universal-apple-darwin.tar.gz` archive.
- `scripts/fetch_gitpm.py` downloads that archive, verifies it against the pinned and the published SHA-256 and the tag against the pinned commit, checks both architecture slices and installs the XCFramework and generated Swift API where `scripts/build-gitpm.sh` puts them.
- CI and the Release workflow install the pinned release instead of checking out and compiling gitpm; they no longer install Rust targets.
- `scripts/build-gitpm.sh` stays for local development from gitpm sources; without sources it keeps an installed release. Building the pinned commit from source keeps working.
- The gitpm pin is bumped by hand together with any Swift change a new plugin manager API needs; there is no automatic bump.

## Impact
Development, release packaging and release publishing specifications, CI and Release workflows, a new fetch script and its test, operator documentation.
