# Tilr native plugins

Independent macOS plugin repository. Browser WebKit and native audio compile to
signed `.tilrplugin` packages and install outside `Tilr.app`. The application
links only the SDK ABI headers; it does not compile either implementation.
Chromium is not included.

| Directory | Responsibility |
| --- | --- |
| `SDK/Sources/TilrPluginABI` | Versioned Objective-C binary contract and C factory entry point |
| `SDK/Sources/TilrPluginViews` | Generic AppKit surfaces, placement, stacking, masks and hit testing |
| `Sources/BrowserWebKit` | Browser WKWebViews, profiles, proxies, tunnels, native automation |
| `Sources/NativeAudio` | AVPlayer, Now Playing and media keys |
| `manifests` | Independently versioned package manifests |
| `scripts/plugin.py` | Build, verify, install, list and rollback |

The existing Cordis `webviews` / `audio` contracts, browser UI plugin and Webamp
continue to work. The `tilrWebViews` and `tilrAudio` bridge aliases are declared
by these packages, not hardcoded into Tilr's loader. New plugins can use the
generic `tilrNative` bridge: `connectNative()` from `'tilr/native'`, a module of the
Tilr page (its import map; types in `@tilr-dev/plugin`, see `../../web/docs/plugin-sdk.md`).

## Build and install

Requires macOS, Python 3, Xcode/Command Line Tools with Swift 6, and the following
checkout layout (the SDK is a local package of the app):

```text
tilr/
  tilr-mac/              application repository
    native-plugins/      this folder, including SDK/
  git/gitpm/             gitpm (github.com/tilr-dev/gitpm)
  web/                   web SDK repository (for the page and JS bridge tests)
```

```sh
python3 scripts/plugin.py build
# Or select a plugin and architecture:
python3 scripts/plugin.py build audio --arch arm64 --version 0.1.1

# Local ad-hoc builds go into an independently signed development/test app:
python3 scripts/plugin.py install dist/arm64/audio.tilrplugin \
  --app ../build/Tilr.app --development \
  --directory /tmp/tilr-test/native-plugins

python3 scripts/plugin.py list --directory /tmp/tilr-test/native-plugins
python3 scripts/plugin.py rollback audio --app ../build/Tilr.app \
  --development --directory /tmp/tilr-test/native-plugins
```

For a Developer ID build, supply `build --identity 'Developer ID Application: …'`
using the same publisher as Tilr, then install with `--app /Applications/Tilr.app`
and without `--development`. Build and distribute one package per architecture
(`arm64` or `x86_64`). A user installing a ready package needs no Swift toolchain.

The installer verifies the signature/resource seal, architecture, manifest and
SDK ABI. With `--app`, it also executes the app's headless factory probe before
activation. Installation stages a copy, re-verifies it, then atomically changes
`active.json` under a lock. Existing versions are immutable: bump the plugin's
version to update it. A failed check leaves the active version unchanged.

## Runtime and updates

Both initial plugins use **in-process modules**. They are trusted native code,
not sandboxed extensions. A plugin failure can affect the app. The initial
publisher policy accepts the app's signing team; ad-hoc development apps accept
valid ad-hoc plugins. Users of release builds can explicitly allow other publishers
and ad-hoc packages in their instance's `config.yml` (Tilr → Native Plugin Settings…):

```yaml
native_plugins:
  allow_third_party: true
  enabled: [browser-webkit, audio, my-plugin]
```

This permission defaults to false and takes effect **after restart**, including
when disabling it. Native code already loaded into the process cannot be revoked
or unloaded. About reports the loaded versions, errors, and third-party providers.
The setting does not install every package: only IDs in `enabled` are loaded.

A plugin author can fork this repository, add a dynamic SwiftPM product using the
SDK and a `manifests/my-plugin.json`, then build without an Apple Developer account:

```sh
python3 scripts/plugin.py build my-plugin --arch arm64 --version 0.1.0
python3 scripts/plugin.py install dist/arm64/my-plugin.tilrplugin \
  --app /Applications/Tilr.app --allow-third-party
```

The build adds a free ad-hoc signature. Completely signatureless or damaged
packages remain rejected. `--allow-third-party` accepts the package's publisher
in the installer; the app's probe separately checks the target instance's permission
before activating it. For a custom plugin directory, supply `--config INSTANCE_DIR`
if the instance config is not its parent. Neither command edits the user's permission.

Release hosts carry Apple's `com.apple.security.cs.disable-library-validation`
entitlement to support the user's choice. This exception is fixed at signing time;
the configuration is a Tilr loader policy, not a switch for the OS entitlement.
Third-party native code runs with Tilr's process access. ABI 1 provides no sandbox
or subprocess isolation. Downloaded packages may additionally be subject to macOS
Gatekeeper/quarantine policy; the installer does not remove quarantine.

Installing/updating a native package never replaces or rebuilds the application.
**Restart Tilr to load a newly installed native version.** The loader never
unloads Swift/Objective-C code, and it pins a loaded module for the process's
lifetime. Web plugin reloads continue to work without restarting Tilr.

Each app/tab gets a native session. On page navigation (a reload, a site rebuild)
browser views created with a `key` are parked and can be adopted by the returning UI
(below); the others are released. Audio players survive a page reload and can be
adopted by the returning UI.
Closing a tab stops all its native resources. Installing a new audio binary does
not preserve playback across an application restart.

The default configuration enables `browser-webkit` and `audio`:

```yaml
native_plugins:
  allow_third_party: false   # other publishers/ad-hoc packages; at launch
  directory: native-plugins   # relative to the instance's config directory
  enabled: [browser-webkit, audio]
  request_timeout: 30         # seconds; at launch
  options: {}                 # plugin id → plugin-owned JSON settings; hot reloaded
```

`<config>/native-plugins/<id>/active.json` selects
`<config>/native-plugins/<id>/<version>.tilrplugin`. Without an installed version,
Tilr uses `Contents/PlugIns/<id>.tilrplugin` as its bootstrap package. An invalid
explicitly selected package is reported as unavailable; it does not silently
switch to an older implementation. Use rollback to select a previous version.
Installed selections survive app updates, even when a bundled package is newer.

The main WKWebView that displays Tilr's interface remains in the application.
The browser plugin owns the embedded browser windows. System WebKit itself is
provided by macOS. iPad keeps its existing built-in implementation.

## SDK contract

Read [`SDK/Sources/TilrPluginABI/include/TilrPluginABI.h`](SDK/Sources/TilrPluginABI/include/TilrPluginABI.h).
A module exports `tilr_plugin_create_v1`, returning a retained object conforming
to `TLRNativePlugin`. Only Objective-C/Foundation/AppKit values cross the binary
boundary; no app Swift types or Swift compiler-specific layouts are exposed.

All calls and callbacks use the main thread. Retain the host weakly. `stop()` must
release resources and stop emitting events; cancel outstanding control tasks in
`cancelRequest`. A page navigation and a session stop are different events.
Breaking changes to required selectors or semantics require a new ABI version.
The app accepts only ABI 1; native plugin versions are independent of app versions.

Plugin-specific `native_plugins.options.<id>` is delivered as
`host.configuration["options"]`, with `configurationDidChange` on config reload.
The existing `browser:` section remains available to the WebKit provider as
`host.configuration["browser"]`. The host adds two keys of its own to that map,
over any user key of the same name (they are not keys of the config's `browser:`):
`inspectable` (`debug.inspectable`) and `high_refresh_rate` (`web.high_refresh_rate`:
render at the display's native rate instead of WebKit's 60 Hz cap). Both are the
values the tab was made with, i.e. they apply at launch.

The WebKit provider reads these `browser:` keys (defaults and comments in the app's
`default.yml`); a key a host does not send takes the same default:

| Key | Default | Effect |
| --- | --- | --- |
| `automation_frames` | `all` | Frames that get the automation script; `main` skips iframes (ads), so automation cannot target one. For views made after the change |
| `live_resize_interval` | `40` | Milliseconds between relayouts of an embedded page while its rect keeps changing size; the last size is always applied. `0`: every change. Also the delay before a view gone hidden is pictured for discarding. On reload |
| `progress_interval` | `100` | Milliseconds between `tilr-webview` reports that change only `progress`; identical reports are dropped, the start and end of a load and every other change go at once. On reload |
| `adopt_grace` | `10` | Seconds a parked view (a keyed view of a page that navigated) waits for the new page to adopt it before it is disposed; `0`: no parking, every view goes with the page. Read at each navigation |
| `automation_timeout` | `10` | Seconds one automation JavaScript operation may take; also the most a discard waits for its media check and how long a view coming back keeps its picture while its page does not finish. On reload |
| `discard_after` | `0` | Seconds a view stays hidden (not visible to the page, covered, off-screen, parked, in a concealed tab, in a window that is occluded, minimized or on another Space) before its web content is released (below); `0`: never. On reload |
| `inspectable` (host) | `true` | `WKWebView.isInspectable` of each view |
| `high_refresh_rate` (host) | `false` | Turns WebKit's 60 Hz cap off on the view's preferences (guarded SPI, `WebKitFeatures.swift`; unavailable: logged once, 60 Hz) |

Views across a reload of the page (`webviews` protocol, `WebViews.swift`): `create`
takes an optional `key` (a string the page keeps for the same logical view across its
reloads; the browser plugin sends its window's id). On `pageDidNavigate` a view with a key
is parked instead of removed: hidden, out of the focus, media suspended
(`setAllMediaPlaybackSuspended`), no `tilr-webview` reports, not in `browser list`, kept
`adopt_grace` seconds (one per key). A `create` of the new page with that `key` and an
equal `profile` adopts it: the view takes the new `id`, loads nothing (the create's `url` is
ignored: the live view is at least as recent as the page's saved URL; the page takes the
view's), resumes its media, is shown by the next `place`, and its first report is the whole
state plus `adopted: true`. Another profile cannot be given to a made view: the parked one
is disposed and a new view made. Views not adopted in time, views without a key, all views
with `adopt_grace: 0`, and every view on session stop are disposed as before.

Discarding (`discard_after` > 0, `WebViews.swift`): a view hidden that long (its last `place`
did not show it, it was never placed, it is parked, an ancestor is hidden — the host
concealing the tab, seen through `viewDidHide` / `viewDidUnhide` — or its window lacks
`.visible` in `occlusionState`: occluded, minimized, on another Space, followed through
`didChangeOcclusionStateNotification`) releases its web content. The page's `visible` (in
`browser list`) stays what the page placed; only `discarded` follows the rest. Its picture is
taken `live_resize_interval` after it went hidden (`takeSnapshot`, public, without waiting for
a rendering update: a hidden view gets none; one at a time, cancelled if it is shown first; a
failed one keeps the last picture; a view back from a discard while still hidden is pictured
again) and, at the discard, its `interactionState` (public, macOS 12: the back/forward list and the current
entry's scroll), its URL, title and history flags; the WKWebView is then dropped (delegates,
KVO and the automation handler removed, media closed, loading stopped, out of the view tree), so
its WebContent process exits. The picture (`NSImageView`, scaled to fill, transparent to the
mouse) stays in the surface; id, key, profile and proxy lease stay. Reports carry
`discarded: true|false` (always present); `browser list` rows carry `discarded` too. A view
playing media, capturing camera or microphone, in fullscreen, or waiting for its proxy is kept
and checked again after another `discard_after` (the media check waits up to
`automation_timeout`; it holds the web view weakly, so a dropped one goes at once). A discarded view comes back on a `place` that
shows it, on `navigate` / `back` / `forward` / `reload`, and on any automation command but
`navigate` (which waits for the page, up to `automation_timeout`): a new WKWebView of the same
configuration and store, given the `interactionState` (the current entry loads again; script
state, forms and media are lost), under the picture, which goes at its first `didFinish` or after
`automation_timeout`; when the load failed, the picture stays (the error is reported) until a
load finishes. A parked view runs the same timer; adopting a discarded view keeps it discarded
until the new page's `place` shows it. Measured (three tiles, two covered, `discard_after: 15`):
both discarded at 15.3 s, their WebContent processes (46 and 93 MB) exited with the
discard (re-measured: within the same 0.25 s poll; ~10 s later while the media check still
held the view),
the GPU process went 67 → 47 MB; shown again, Wikipedia was loaded with its scroll back in 3.5 s.

Focus: a surface hidden by `place` (covered, off its parent, `visible: false`) while it or
a view in it was first responder remembers that; shown again by a later `place`, it takes
the focus back if the window's first responder is still what AppKit chose when it was
hidden (nothing else took the focus meanwhile).

Placement (`TilrPluginViews.ViewSurface.place`): a surface off its parent's bounds, or
whose visible part the union of its holes covers entirely (one float, or several side by
side), is hidden like `visible: false`, so WebKit stops its rendering updates (rAF,
animations; page timers are throttled as for a hidden page) while automation `evaluate` still
answers; a partly covered one stays shown and masked. Moves apply at once; size changes
reach the content at most once per `resizeInterval` (trailing: the final size always lands),
the content meanwhile keeping its last size, anchored top left and clipped by the surface,
whose background is the views' under-page colour (white, set on every view). Hidden or covered views keep playing their
media; a view's removal closes its media presentations (picture in picture, fullscreen) and
pauses its playback before it stops loading.

The host provides a view container, JSON configuration, event delivery, site URL
resolution, and stable instance-scoped storage identifiers. Browser cookies and
profile IDs therefore keep their pre-extraction locations. `TilrPluginViews`
provides `ViewOverlay` and `ViewSurface` for arbitrary AppKit views, without a
dependency on WebKit or Tilr internals.

Native control services are reachable only over Tilr Control, not the web bridge.
Web messages are accepted only from the trusted top-level app origin; browser
pages and subframes get no native bridge. Events are origin-checked again inside
the destination JavaScript to prevent delivery across navigation.

```js
import { connectNative } from 'tilr/native'
const native = connectNative()
const providers = await native.describe()
const off = native.on('tilr-audio', state => console.log(state))
await native.send('audio', 'audio', { op: 'list' })
// send acknowledges dispatch; the provider's events deliver state/results.
off()
native.dispose()
```

Manifest fields: `id`, numeric `version` (`major.minor.patch`), `abi`, `minOS`,
`bridges` (legacy handler → channel), `services` (native control endpoints),
`events`. The source manifest additionally selects the SwiftPM `product` to pack.
Duplicate services/handlers and reserved handler names are rejected. The SDK is a
separate Swift package and can be used by plugin repositories outside this tree.

## Verification

```sh
swift test --disable-sandbox
swift test --disable-sandbox --package-path SDK
# The JavaScript bridge ('tilr/native') is tested in ../../web: src/tilr/native.test.ts (npm run test:unit)
python3 ../scripts/test_native_plugins.py
# In a logged-in desktop session, includes the existing browser and app probes:
python3 ../scripts/test_native_plugins.py --gui
```

The package tests exercise real signed modules and the actual app loader:
bootstrap loading, external installation, version selection, rollback, unchanged
app binary/signature, tampering, ABI mismatch and missing entry point.

Inspect a running app with `tilr ctl native-plugins` and
`tilr ctl native-call audio '{"op":"list"}'`. Existing browser automation commands
continue to route through the native browser provider. For headless validation:

```sh
/path/to/Tilr.app/Contents/MacOS/Tilr --check-native-plugin /path/to/audio.tilrplugin
/path/to/Tilr.app/Contents/MacOS/Tilr --config /tmp/tilr-test --check-native-plugins
```

`../run.sh` and release packaging include bootstrap packages. Public app
releases sign them with the app's identity and include them in notarization.
The vendor release set is every `manifests/*.json` in this repository. Add the
manifest and its SwiftPM dynamic product to include a new vendor plugin in future
app releases automatically (also with `release.py --native-plugins DIR`).
The CI build job packages plugins for both architectures; the publication job uploads
those completed DMGs without rebuilding. `release.json` records plugin IDs,
versions, ABIs and binary checksums. Publishing checks the inventory against the
bundled packages and refuses architecture pairs with different versions/ABIs.
Plugin versions are independent: update their source manifests when making a new
plugin release; changing the app's build number does not bump plugin versions.
These commands include bootstrap packages in the app update, not a separate
automatic plugin feed. An external active version continues to take precedence.
Independent plugin distribution may use Developer ID signing/notarization for
normal macOS distribution, or ad-hoc packages with user opt-in as above. This CLI
does not publish or notarize independent packages automatically.
