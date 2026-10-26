#!/bin/sh
# Run from the source repository; keep release numbering out of development bundles.
set -eu
base=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null) || base=v0.0.0
hash=$(git rev-parse --short=7 HEAD 2>/dev/null) || hash=unknown
dirty=
[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=.dirty
printf '%s-dev.%s%s\n' "${base#v}" "$hash" "$dirty"
