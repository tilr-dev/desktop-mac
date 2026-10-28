# Tilr Mac releases

The [production release guide](PRODUCTION.md) describes the CI release workflow,
credentials, automatic server pins and artifact verification. Push a fix to
`release/X.Y` to build an RC for beta; merge the release-please PR to build and
publish stable from its tag. CI allocates builds from all published appcasts.

For local development and tests use `run.sh`. Completed CI artifacts can be checked
with `scripts/verify_release.py`; GUI and Sparkle tests still require a matching Mac.

## Configuration and app folders

The default config is `~/Library/Application Support/dev.tilr.mac/config.yml`.
`--config DIR` overrides its folder, followed by `TILR_CONFIG`. This also selects
an independent instance. `run.sh --test` defaults to the sibling `dev.tilr.mac.test`.

The default `site: apps/default` is relative to the config folder. Both `site:` and
each `apps:` entry accept config-relative paths, absolute paths, and `~/…`.
Use `--site DIR` to open a different web app for one launch (relative command-line
paths are relative to the working directory), for example:

```sh
open /Applications/Tilr.app --args --site "$HOME/projects/dashboard/site"
```

Web installers and Control use the same default config folder and honor
`TILR_CONFIG`; installer `--site` or `TILR_SITE` overrides the install destination.
With multiple `apps:` entries, select the install destination with `--site`.

Existing files in `~/.config/tilr` and `~/tilr` are not moved automatically.
To keep an old setup, copy its config.yml into the new config folder, retaining
its explicit site/apps paths, or launch with `--config "$HOME/.config/tilr"`.

### Application icon

`Resources/AppIcon.svg` is the green r favicon from the Tilr landing page
(`~/design/landings/tilr/index.html`). `Resources/AppIcon.icns` contains standard
and Retina sizes and is copied into Resources by both run.sh and release.py,
before signing. Info.plist declares CFBundleIconFile=AppIcon. To regenerate:

```sh
swift scripts/make_icon.swift /tmp/Tilr.iconset Resources/AppIcon.icns
```

The icon ships in the app bundle, so a normal Sparkle update also installs it.

### Update choice policy

New feeds use generate_appcast --critical-update-version with an empty value.
Sparkle marks these updates critical for all installed versions; its standard UI
hides both Skip This Version and Remind Me Later. Closing the update window still
dismisses this prompt without recording the version as skipped. Installation still
requires consent; this does not enable silent/forced installation. Sparkle may present
critical updates sooner and label them important. Previously published feeds are not
rewritten by resume; this policy applies to newly generated feeds.

### CDN verification and negative caching

Cloudflare can cache a pre-upload 404 for a DMG URL for 180 seconds. The publisher
checks existence using a unique query key, uploads if missing, and then verifies
the canonical download URL and SHA-256 before updating the feed. Canonical 404s
are retried for up to 200 seconds to cover caches from earlier attempts. A checksum
mismatch still fails immediately. Inspect the failed CI publication before releasing again; do not rebuild or change
immutable DMGs to work around a cached 404.

### Native update reminders

`AppUpdates` is a separate Swift library target/product in this package. The host
retains `AppUpdates(updaterDelegate:)`, calls `start()` after opening its window,
and uses its `controller` for Check for Updates and About. A host with its own
UNUserNotificationCenter delegate must forward update notification callbacks.
Feed URL and public key still come from the signed host bundle.

Sparkle checks every hour while the app is running (`SUScheduledCheckInterval` in
Info.plist, in seconds; Sparkle enforces a one-hour minimum). It uses the last
check time when scheduling after launch and respects saved user preferences.

Scheduled updates show a native macOS banner and a persistent Dock arrow. Clicking
the banner or Check for Updates opens Sparkle's install dialog. Permission denial
uses Sparkle's normal presentation; notification submission errors also open it.
Manual checks keep the normal UI. Reminders are cleared when the update receives
attention or its session ends. macOS controls banner appearance and Focus filtering.
Downloads/installation remain governed by Sparkle's preferences and user consent.
Development builds, `--probe` and `--no-updates` never start this module.

Acceptance on two signed builds: allow notifications, let a scheduled check find
the newer build, verify banner and Dock arrow, click and install/relaunch; repeat
with notifications denied and with a manual check. Opening About only requests
version information and must not post a banner. Verify dismissal clears reminders.
