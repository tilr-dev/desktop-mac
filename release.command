#!/bin/bash
# Automatic build only; signing settings come from release.local.json / environment.
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -f release.local.json ]; then
    echo "Configure signing once: ./setup-release.command"
    exit 1
fi
exec python3 scripts/release_all.py --auto "$@"
