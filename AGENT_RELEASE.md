# Releases operated by an agent

Use [PRODUCTION.md](PRODUCTION.md) for the CI release workflow. Release publication
runs only in CI: a push to `release/X.Y` builds an RC for beta, and merging the
release-please PR builds stable from its tag. Follow the repository's authorization
rules for branch pushes and PR merges.

For local development use `run.sh`. To inspect completed CI artifacts, download the
release directories and run `scripts/verify_release.py`; report exact version,
build, architecture, hashes and verification results. A verifier receipt records
artifact checks, not a GUI or Sparkle installation test.

CI receives scoped credentials in separate build and publication jobs. Do not print
secrets, create replacement certificates, bypass Keychain restrictions or request
interactive credentials for a local release. The upstream tilrd release opens the
server pin update PR automatically; inspect that PR through the normal review path.

If a release fails, report the failing job and step. Preserve completed artifacts
and immutable published bytes. A new fix push produces a fresh candidate and build.
Do not claim live release, notarization, CDN or GUI behavior passed from unit tests.
