#!/bin/bash
# Publish completed application artifacts; never rebuild them.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"
latest=1
explicit_channel=
for arg in "$@"; do
    case "$arg" in
        --version|--version=*|--build|--build=*) latest=;;
        --channel|--channel=*)
            explicit_channel=1;;
    esac
done
if [ -n "$explicit_channel" ] && [ -n "$latest" ]; then
    python3 -c 'import sys; sys.path.insert(0, "scripts"); from release_console import failure; failure("The latest build already has a channel. Omit --channel, or select --version and --build explicitly.")'
    exit 1
fi
if [ -n "$latest" ]; then
    exec python3 scripts/release_all.py --publish-only --latest "$@"
fi
exec python3 scripts/release_all.py --publish-only "$@"
