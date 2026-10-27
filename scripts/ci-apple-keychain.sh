#!/bin/bash
# Release runner only. `import`: a temporary default keychain with the Developer ID identity
# (APPLE_CERTIFICATE_P12_BASE64, APPLE_CERTIFICATE_PASSWORD, APPLE_SIGN_IDENTITY) and the
# notarytool profile tilr-ci (App Store Connect API key: APPLE_API_KEY_P8_BASE64,
# APPLE_API_KEY_ID, APPLE_API_ISSUER_ID). Key files exist under RUNNER_TEMP only until imported.
# `cleanup`: restores the previous default keychain and deletes the temporary one.
set -euo pipefail
: "${RUNNER_TEMP:?runner only}"
keychain="$RUNNER_TEMP/tilr-release.keychain-db"
previous="$RUNNER_TEMP/tilr-release.previous-keychain"

case "${1:-}" in
  import)
    for name in APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGN_IDENTITY \
                APPLE_API_KEY_P8_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
      if [ -z "${!name:-}" ]; then
        echo "Missing secret $name in the apple-signing environment (PRODUCTION.md, Release from CI)" >&2
        exit 1
      fi
    done
    umask 077
    password=$(openssl rand -base64 32)
    security default-keychain -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//' > "$previous"
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$password" "$keychain"
    trap 'rm -f "$RUNNER_TEMP/certificate.p12" "$RUNNER_TEMP/AuthKey.p8"' EXIT
    printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/certificate.p12"
    security import "$RUNNER_TEMP/certificate.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -x -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null
    keychains=("$keychain")
    while IFS= read -r existing; do
      keychains+=("$existing")
    done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
    security list-keychains -d user -s "${keychains[@]}"
    security default-keychain -d user -s "$keychain"
    printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$RUNNER_TEMP/AuthKey.p8"
    xcrun notarytool store-credentials tilr-ci --key "$RUNNER_TEMP/AuthKey.p8" \
      --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --keychain "$keychain"
    if ! security find-identity -v -p codesigning "$keychain" | grep -qF "\"$APPLE_SIGN_IDENTITY\""; then
      echo "APPLE_SIGN_IDENTITY is not the identity in APPLE_CERTIFICATE_P12_BASE64" >&2
      exit 1
    fi
    ;;
  cleanup)
    if [ -s "$previous" ]; then
      security default-keychain -d user -s "$(cat "$previous")" || true
    fi
    if [ -f "$keychain" ]; then
      security delete-keychain "$keychain"
    fi
    rm -f "$previous" "$RUNNER_TEMP/certificate.p12" "$RUNNER_TEMP/AuthKey.p8"
    ;;
  *)
    echo "usage: $0 import|cleanup" >&2
    exit 2
    ;;
esac
