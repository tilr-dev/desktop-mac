#!/bin/bash
# Automatic build only; signing settings come from release.local.json / environment.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"
exec python3 scripts/release_all.py --auto "$@"
