#!/bin/bash
# One-time local bootstrap; no build and no publication.
set -euo pipefail
cd "$(dirname "$0")"
trap 'result=$?; read -r -p "Press Return to close… " _ || true; exit "$result"' EXIT
echo "Configure Tilr release signing on this Mac. No DMGs will be built or published."
security find-identity -v -p codesigning
read -r -p "Developer ID Application identity for Rexuni (full name, SHA-1, or list number): " TILR_SIGN_IDENTITY
export TILR_SIGN_IDENTITY
export TILR_NOTARY_PROFILE=tilr-rexuni
swift package resolve
sparkle_bin="$PWD/.build/artifacts/sparkle/Sparkle/bin"
"$sparkle_bin/generate_keys" --account tilr-rexuni
TILR_UPDATE_PUBLIC_KEY=$("$sparkle_bin/generate_keys" --account tilr-rexuni -p)
export TILR_UPDATE_PUBLIC_KEY
if ! xcrun notarytool history --keychain-profile "$TILR_NOTARY_PROFILE" >/dev/null; then
    echo "Enter Apple notarization credentials only at Apple's prompt."
    echo "Apple ID flow: app-specific password from account.apple.com → Sign-In and Security."
    echo "Team ID: Rexuni's code in the suffix of the certificate name."
    xcrun notarytool store-credentials "$TILR_NOTARY_PROFILE"
fi
python3 - <<'PY'
import base64, json, os, re, subprocess
from pathlib import Path
names = ('TILR_SIGN_IDENTITY', 'TILR_NOTARY_PROFILE', 'TILR_UPDATE_PUBLIC_KEY')
settings = {name: os.environ[name] for name in names}
selection = settings['TILR_SIGN_IDENTITY'].strip().strip('"')
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
matches = []
for number, fingerprint, name in re.findall(r'^\s*(\d+)\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', identities, re.MULTILINE):
    if selection == number or selection.lower() == fingerprint.lower() or selection == name:
        if name.startswith('Developer ID Application:'):
            matches.append(name)
if len(matches) != 1:
    raise SystemExit('Choose exactly one available Developer ID Application certificate; rerun setup. Saved notarization credentials and Sparkle keys are retained.')
settings['TILR_SIGN_IDENTITY'] = matches[0]
assert len(base64.b64decode(settings['TILR_UPDATE_PUBLIC_KEY'], validate=True)) == 32
Path('release.local.json').write_text(json.dumps(settings, indent=2) + '\n')
PY
# The selected fingerprint/list number was normalized in the saved file. Do not
# let the original exported input override that name in the preflight process.
TILR_SIGN_IDENTITY=$(python3 -c 'import json; print(json.load(open("release.local.json"))["TILR_SIGN_IDENTITY"])')
export TILR_SIGN_IDENTITY
python3 scripts/release_all.py --check
echo "Signing setup complete. No release created or uploaded."
echo "For publishing, configure Wrangler login separately and run: python3 scripts/release_all.py --check --publish-only"
