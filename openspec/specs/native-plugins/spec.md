# native-plugins Specification

## Purpose
TBD - created by archiving change bootstrap-desktop-mac. Update Purpose after archive.

## Requirements

### Requirement: Independent plugin packages and ABI
Tilr SHALL load native packages built against the separate SDK, without exposing app Swift types or compiler layouts across the ABI; provider implementations stay outside the app target, generic placement stays in TilrPluginViews, and Chromium is not included.

#### Scenario: Load a module
- **WHEN** an ABI 1 module is loaded
- **THEN** `tilr_plugin_create_v1` returns a retained TLRNativePlugin object using Objective-C/Foundation/AppKit boundary values; calls and callbacks run on the main thread and the host is retained weakly
- **AND** stop releases resources and stops events, cancelRequest cancels outstanding control work, and breaking required selectors/semantics require a new ABI
- **AND** manifests declare id, numeric major.minor.patch version, abi, minOS, bridges, services and events; source manifests also select the SwiftPM product; duplicate services/handlers and reserved handlers are rejected
- **AND** existing browser/audio aliases and the generic `tilrNative` bridge remain supported without requiring web-plugin changes

### Requirement: Verified installation and persistent selection
Tilr SHALL install immutable, per-architecture plugin versions without modifying the application bundle and select them atomically through active.json.

#### Scenario: Install or roll back
- **WHEN** the plugin CLI builds, signs, installs, lists or rolls back a package
- **THEN** installation verifies seal, architecture, manifest and ABI, optionally probes the factory with `--app`, stages and reverifies under a lock, and atomically updates selection
- **AND** build supports plugin id, --arch, --version and --identity; --development permits ad-hoc development-app checks, --directory selects external storage, and ready-package users need no Swift toolchain
- **AND** failure preserves the previous selection; rollback selects a retained prior version
- **AND** `<config>/native-plugins/<id>/active.json` selects `<version>.tilrplugin`, taking precedence over bundled `Contents/PlugIns/<id>.tilrplugin` across app upgrades
- **AND** an invalid explicit selection is unavailable with an error, without silently falling back to the bundle
- **AND** a loaded module remains pinned until process exit; installing another binary does not preserve audio across an app restart

### Requirement: Native code trust policy
Tilr SHALL treat native plugins as in-process trusted code and require signed, intact packages, accepting the app's signing team by default.

#### Scenario: Opt into another publisher
- **WHEN** a different-team or ad-hoc package is selected
- **THEN** a release host permits it only with launch-time `native_plugins.allow_third_party: true` and an enabled plugin id; unsigned or damaged packages are still rejected
- **AND** an ad-hoc development host accepts valid ad-hoc packages by default
- **AND** either direction of this permission change requires restart; installer `--allow-third-party` and `--config` never edit the app's permission
- **AND** library-validation entitlement is fixed at app signing, quarantine is retained, and the package remains subject to macOS distribution policy

#### Scenario: Inspect and configure plugins
- **WHEN** the user opens About or Native Plugin Settings
- **THEN** About shows actually loaded versions, third-party publishers and errors; Native Plugin Settings opens this instance's config.yml
- **AND** enabling an id or granting publisher permission does not install every package

### Requirement: Session and host isolation
Tilr SHALL create a native session per app/tab, keep the main interface WKWebView in the app and embedded browser views in the browser plugin, and retain instance-scoped profile storage identifiers.

#### Scenario: Configure a session
- **WHEN** a session starts or configuration reloads
- **THEN** enabled defaults are browser-webkit and audio, request timeout defaults to 30 seconds at launch, and plugin options hot reload through configurationDidChange
- **AND** browser configuration is provided separately, with host inspectable/high_refresh_rate values overriding user keys and fixed to the tab's launch values
- **AND** the SDK supplies generic AppKit overlay/surface containers, JSON configuration, event delivery and site URL resolution without depending on app internals; existing browser cookies and profile locations remain stable, macOS supplies system WebKit and iPad retains its built-in implementation
- **AND** closing a tab stops all native resources; navigation and session stop are distinct, and audio survives page navigation

### Requirement: Trusted message and event delivery
Tilr SHALL accept native web messages only from the trusted top-level app origin, recheck event destinations after navigation and reserve native control services for Control.

#### Scenario: Dispatch a message
- **WHEN** the page describes providers, subscribes to events or sends a native message
- **THEN** browser pages and subframes cannot use the bridge; send acknowledges dispatch and provider events carry results/state
- **AND** unsubscribe/dispose stops subscriptions; queued events cannot be delivered to another origin after navigation

### Requirement: Browser adoption after page navigation
The browser provider SHALL park keyed views for `browser.adopt_grace` seconds (default 10), allowing a returning page to adopt a matching profile without reloading it.

#### Scenario: Adopt a keyed view
- **WHEN** navigation parks a keyed view
- **THEN** it is hidden and unfocused, media is suspended, reports stop and browser list excludes it
- **AND** create with the same key/profile adopts it under the new id, ignores the supplied URL, resumes media, waits for place to show it and emits complete state with `adopted: true`
- **AND** mismatched profiles, unkeyed views, expired views, zero grace and session stop dispose the old view

### Requirement: Browser reporting and automation configuration
The browser provider SHALL honor documented defaults for automation and layout without flooding progress updates.

#### Scenario: Configure browser work
- **WHEN** views are created or browser config reloads
- **THEN** automation_frames defaults to all (main excludes iframes) and applies to new views, automation_timeout defaults to 10 seconds, live_resize_interval to 40 milliseconds, progress_interval to 100 milliseconds and discard_after to zero (disabled)
- **AND** progress-only reports are throttled, identical reports are dropped, and load start/end and other changes are immediate
- **AND** live resize always applies the final size; zero interval applies every change

### Requirement: Hidden browser discard and restoration
The browser provider SHALL optionally release hidden web content after discard_after while preserving its surface identity, profile, proxy lease, URL/title/history and interaction state.

#### Scenario: Discard and restore
- **WHEN** a view is hidden, fully covered, outside bounds, parked, in a concealed tab or an occluded/minimized/other-Space window for the configured duration
- **THEN** its picture is captured after live_resize_interval with at most one pending capture (cancelled if shown); failures retain the previous picture
- **AND** discard detaches handlers/delegates, stops loading/media and releases the WKWebView; reports and browser list always contain discarded, while visible remains the page's placed visibility
- **AND** media playback, capture, fullscreen or a pending proxy prevent discard and schedule another check; media checks are bounded by automation_timeout and do not retain a released view
- **AND** visible place, navigation/history/reload or automation restores the same configuration/store and interaction state; current content reloads, losing script/forms/media state
- **AND** the mouse-transparent picture remains until load finishes or automation_timeout, and remains after failure until a successful load; adopting a discarded view leaves it discarded until shown

### Requirement: Browser placement and focus
Native view surfaces SHALL apply moves immediately, throttle trailing size changes and correctly mask partial coverage or hide complete coverage by the union of holes.

#### Scenario: Cover and reveal
- **WHEN** placement hides a focused surface
- **THEN** rendering updates stop while automation evaluation still answers (click and hover refuse hidden views) and hidden media continues; a partially covered surface stays shown and masked
- **AND** content retains its last size anchored top-left and clipped during resize, with its under-page color behind it; the final size is always applied
- **AND** reveal restores focus only if no other responder took focus meanwhile; removal closes picture-in-picture/fullscreen presentations and pauses media before stopping loading

### Requirement: Plugin verification and release inventory
Tilr SHALL support headless `--check-native-plugin PATH` and `--check-native-plugins` and ship all vendor manifests as bootstrap packages in development and release builds.

#### Scenario: Package a public release
- **WHEN** release packaging builds plugins, optionally from `--native-plugins DIR`
- **THEN** both architectures are signed with the app identity and notarized with it; release.json records plugin ids, versions, ABIs and binary checksums
- **AND** publication verifies bundled inventory and rejects architecture pairs differing in plugin version/ABI
- **AND** plugin versions are independent of app build numbers; publication uploads completed app packages without rebuilding and introduces no separate automatic plugin feed or independent-package notarization/publication
