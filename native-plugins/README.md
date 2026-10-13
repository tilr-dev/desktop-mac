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
Tilr page (its import map; types in `@tilr-dev/plugin`, see `../web/docs/plugin-sdk.md`).

## Build and install

Requires macOS, Python 3, Xcode/Command Line Tools with Swift 6, and the following
checkout layout for the app's local SDK dependency:

```text
tilr/
  apps/mac/          application repository
  native-plugins/    this repository, including SDK/
  web/              existing web SDK repository
  plugins/browser/  existing browser UI repository
```

```sh
python3 scripts/plugin.py build
# Or select a plugin and architecture:
python3 scripts/plugin.py build audio --arch arm64 --version 0.1.1

# Local ad-hoc builds go into an independently signed development/test app:
python3 scripts/plugin.py install dist/arm64/audio.tilrplugin \
  --app ../apps/mac/build/Tilr.app --development \
  --directory /tmp/tilr-test/native-plugins

python3 scripts/plugin.py list --directory /tmp/tilr-test/native-plugins
python3 scripts/plugin.py rollback audio --app ../apps/mac/build/Tilr.app \
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

Each app/tab gets a native session. Browser views are released on page navigation;
audio players survive a page reload and can be adopted by the returning UI.
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
The existing `browser:` section remains available to the WebKit provider.

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
# The JavaScript bridge ('tilr/native') is tested in ../web: src/tilr/native.test.ts (npm run test:unit)
python3 ../apps/mac/scripts/test_native_plugins.py
# In a logged-in desktop session, includes the existing browser and app probes:
python3 ../apps/mac/scripts/test_native_plugins.py --gui
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

`apps/mac/run.sh` and release packaging include bootstrap packages. Public app
releases sign them with the app's identity and include them in notarization.
The vendor release set is every `manifests/*.json` in this repository. Add the
manifest and its SwiftPM dynamic product to include a new vendor plugin in future
app releases automatically (also with `release.py --native-plugins DIR`).
`release.command` builds plugins for both architectures; `upload.command` publishes
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
