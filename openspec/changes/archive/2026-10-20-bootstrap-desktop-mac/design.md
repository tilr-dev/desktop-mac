## Scope and decisions

This change establishes the existing desktop-mac baseline; it changes no runtime,
release tooling or access model. Requirements are ADDED because dev has no prior
OpenSpec specs. Eleven capabilities separate shell/configuration, page serving,
control/diagnosis, native modules, managed server, release production/publication,
development verification and vulnerability policy. Scenarios retain defaults,
lifetimes, failure paths and acceptance limits rather than just listing features.

An alternative was a single documentation capability or a literal copy of each
source document. Capability grouping makes a behavior discoverable in one place
and avoids conflicting copies of repeated release instructions. Existing source
documents remain as operator instructions, command examples and historical evidence.
OpenSpec config uses the standard spec-driven schema without editor integrations.

## Coverage ledger

Paths below are relative to the repository. Sections/line ranges refer to the
source baseline on 2026-10-20 (dev 38bd664). Requirement names are stable lookup
keys within the indicated capability; adjoining scenarios carry operational detail.

| Source | Preserved contracts | Capability / requirements |
| --- | --- | --- |
| CLAUDE.md 3–25, shell and extraction | One window, lazy tabs, layer sliding, watcher/provider lifecycle, SDK-only host, masking, browser adoption/discard, audio | app-shell: One window with configurable presentation; Tab selection and preload. site-serving: Site reload and page lifecycle. native-plugins: Session and host isolation; Browser adoption after page navigation; Hidden browser discard and restoration; Browser placement and focus |
| CLAUDE.md 27–39, gitpm | Static/generated UniFFI, async structured errors, reload workspace/catalog, read-only Control, Git preflight without stub popup | app-control: Plugin manager control and Git errors. development: Isolated development and regression probes |
| CLAUDE.md 41–52, running and frames | run/probe, per-config isolation, modes restore desktop frame, drag/resize hit regions and header click | configuration: Separate application instances. app-shell: One window with configurable presentation. development: Isolated development and regression probes |
| CLAUDE.md 54–68, config and tests | Tunables with comments/units, generated defaults, recursive overrides, reload/launch lifetime, isolated test config and bundle id | configuration: Config directory selection and generated defaults; Settings merging and reload. development: Isolated development and regression probes |
| CLAUDE.md 69–90, private API inventory and memory | Guarded optional SPI, exact feature inventory, fallback/unavailable, desktop confirmation, off-main footprint, system-wide squeeze | performance: Memory diagnosis; Optional private API guards. development: Private API inventory maintenance |
| CLAUDE.md 91–106, Control and refresh | Snapshot/console/call/slide, microtask relay, bounded traversal/serialization, background serving, refresh/inspect lifetime and limits | app-control: Instance control protocol; Bounded console capture. site-serving: Local asset serving. performance: Optional private API guards |
| native-plugins/README.md 3–60, layout/build/install | Separate SDK/provider ownership, existing aliases/generic bridge, package commands, arch/signing/ABI/factory checks, atomic immutable selection | native-plugins: Independent plugin packages and ABI; Verified installation and persistent selection. development: Native plugin verification coverage |
| native-plugins/README.md 64–106, runtime/trust | In-process trust, same-team default, explicit other-publisher/ad-hoc opt-in, enable list, restart both directions, unsigned/damaged refusal, entitlement/quarantine, pinned modules | native-plugins: Native code trust policy; Verified installation and persistent selection |
| native-plugins/README.md 108–157, sessions/config/ABI | Per-tab session, navigation vs stop/audio, external precedence/no invalid fallback, unchanged main WKWebView/iPad/system WebKit, ABI ownership/threading/cancellation, reload options and host overrides | native-plugins: Session and host isolation; Independent plugin packages and ABI; Verified installation and persistent selection |
| native-plugins/README.md 159–184, browser config and adoption | Exact configuration defaults/lifetimes, throttled progress, keyed/profile adoption, grace expiry, complete first report and media | native-plugins: Browser reporting and automation configuration; Browser adoption after page navigation |
| native-plugins/README.md 186–230, discard/focus/placement | Hidden/covered/occluded/Space detection, delayed picture, release/restore interaction state and loss limits, media/capture/fullscreen/proxy exemptions, picture/error lifetime, focus and union-of-holes masking | native-plugins: Hidden browser discard and restoration; Browser placement and focus |
| native-plugins/README.md 232–258, SDK and message contract | Stable stores/generic AppKit container, top-level origin checks on messages/events, Control-only services, dispatch acknowledgement, manifest validation | native-plugins: Session and host isolation; Trusted message and event delivery; Independent plugin packages and ABI |
| native-plugins/README.md 260–299, verification/distribution | Actual signed-loader tests, headless checks, Swift 6 prerequisites, GUI separation, vendor inventory from manifests, same-team notarized bootstrap, independent versions, no separate automatic publishing | native-plugins: Plugin verification and release inventory. development: Native plugin verification coverage |
| RELEASE.md 3–42; PRODUCTION.md 1–80, 482–507; AGENT_RELEASE.md 3–22 | Setup/build/test/upload separation, two DMGs and feeds, readonly status, monotonic reservations, failed/preview history, remembered version, latest successful pair pointer, explicit resume | release-packaging: Separate setup build and publication; Persistent release numbering; Architecture-specific signed artifacts. release-publishing: Verified resume and downloads evidence |
| RELEASE.md 44–95; PRODUCTION.md 350–389; AGENT_RELEASE.md 24–79 | Existing credentials/private key vs Sparkle, prerequisites, non-secret local config/env precedence, scoped publication access, real signing preflight vs publish-only preflight, no permission bypass/key replacement | release-publishing: Credential preflight and secret handling |
| RELEASE.md 97–151; PRODUCTION.md 391–416 | Framework/helper inside-out signing, hardening/timestamp/notarization/stapling, DMG link, no overwrite/user changes/unsigned fallback, completion receipt, channel at build, preview/build switches | release-packaging: Architecture-specific signed artifacts; Build switches and preview isolation |
| PRODUCTION.md 96–143 | Timestamp-only bounded retries, single-arch audit, strip-before-sign with symbols/dSYM retention, unchanged completed servers, logical sizes, bounded verified deltas/full fallback | release-packaging: Bounded timestamp signing retries; Compact packaging evidence; Architecture-specific signed artifacts. release-publishing: Bounded verified app deltas |
| RELEASE.md 153–210; PRODUCTION.md 454–480; AGENT_RELEASE.md 81–119 | Key/feed preferences and identity preservation, exact tested artifacts, receipt/hash/signature/staple checks, feed404/history, immutable downloads/checksums before feed, bounded CDN checks, resume/no downgrade, two non-atomic feeds/single runner, publish-only no rebuild | release-publishing: Immutable publication with feed last; Verified resume and downloads evidence; Application updater lifecycle and consent |
| RELEASE.md 293–348 | Icon, all-new-items critical policy with unchanged resume, host notification callbacks, critical-update consent, cached CDN verification, retained AppUpdates lifecycle, hourly checks/preferences/banner/Dock attention/About, inactive dev/probe | release-packaging: Architecture-specific signed artifacts. release-publishing: Immutable publication with feed last; Application updater lifecycle and consent |
| PRODUCTION.md 61–80, 174–241, 496–507 | Independent server build/version/protocol/channel, offline pin/exact reuse, script switches/receipts/output, signed immutable server feeds, compatible history, public bundle constraints | local-server: Offline bootstrap and independent updates. release-packaging: Independently built server artifacts. release-publishing: Independent signed server publication |
| PRODUCTION.md 243–277 | Managed paths/loopback/private state, direct launchd and login shell, bundle association, strict ownership/migration, no-pane vs pending restart, launchctl comparison/auth ps/kickstart, origins reload | local-server: Managed service ownership and configuration; Safe launchd definition migration |
| PRODUCTION.md 279–333 | Separate menus, actual authenticated running version/off-main refresh, explicit install/24h checks/errors, owned removal with state retention, no BTM-history deletion guarantee, atomic replacement/recovery/session preservation, trusted credentials/test isolation | local-server: Explicit server update controls; Removal preserves user state; Authenticated and compatible replacement; Trusted credential delivery |
| RELEASE.md 212–235, 253–274; PRODUCTION.md 82–87, 335–348, 418–452; AGENT_RELEASE.md 121–132 | Exact DMG verifier/always detach, isolated launch, actual Intel vs compilation, clean browser install, beta N→N+1, external/Unicode paths, app/server independent upgrades and shell PIDs, honest evidence; config-relative/runtime site/installer paths, no legacy migration | development: Exact release verification and evidence. configuration: Config directory selection and generated defaults; Separate application instances. site-serving: App source selection and isolated origins |
| PRODUCTION.md 508–541 | Vendor manifest inventory/receipt/arch parity and explicit third-party opt-in fixed at signing | native-plugins: Plugin verification and release inventory; Native code trust policy |
| SECURITY.md 3–13 | Private reporting URL/details, update/native escape scope, latest release fixes | security: Private vulnerability reporting |

## Source precedence and historical records

RELEASE.md and AGENT_RELEASE.md explicitly point to PRODUCTION.md for the current
default workflow. PRODUCTION's sections titled “implemented” and explicit
“no longer” statements supersede earlier phase descriptions in RELEASE:

- RELEASE 104's universal binary is superseded by PRODUCTION 108–113's
  architecture-specific app and Sparkle audit.
- RELEASE 176–177's initially disabled deltas are superseded by PRODUCTION
  127–143's implemented bounded deltas (default two).
- RELEASE 237–242's future independent server is superseded by PRODUCTION
  174–333's implemented independent update/runtime protocol.
- RELEASE 282's no-server-reuse statement is superseded by PRODUCTION 496's
  completed pinned server reuse; application artifacts still rebuild.
- native-plugins README's introductory “independent repository” describes SDK
  separation; its explicit checkout layout places packages inside desktop-mac.

No historical release number, dated certificate/setup status, measured memory
reduction, old machine PATH observation or claim about absence of macOS APIs is
promoted to a current environment assertion. Those remain historical evidence in
the untouched sources, not product requirements. Prerequisite versions are
documented supported workflow contracts, not claims about this machine's tools.
Old manual verification results do not establish current GUI/Intel/CDN success.

## Source-code references for document gaps

Config.swift/Instance.swift supply precedence, defaults, YAML merge/error handling,
path resolution and instance storage/PID lifetime. Shell.swift/Tab.swift/Site.swift/
SiteSchemeHandler.swift supply selection, placeholders, file response/SPA semantics
and page lifecycle. Control.swift/PluginManagerHost.swift/AgentHost.swift supply
JSON control, read-only plugin-manager and SSH stream behavior. Debug.swift,
PerformanceBridge.swift and Memory.swift supply diagnosis access and file dialogs.
LocalServer.swift/ServerInstallation.swift/ServerUpdates.swift/LocalServerBridge.swift
supply update validation, installation recovery and credential boundaries.

These references clarify existing contracts only. For example the asset resolver
rejects literal parent components; this baseline does not invent a new symlink
containment guarantee. SSH agent forwarding is not described as sharing the
native-plugin message authorization policy. No feature implementation or new
integration test is needed because only specification documents are added.

## Validation

Run `PATH=/opt/homebrew/opt/node@22/bin:$PATH openspec validate --all --strict`
while the change is active, then use the task's standard check/finish workflow.
Finish archives the ADDED deltas into openspec/specs and validates again. The
existing automated suite remains the runtime regression check; manual release
acceptance above describes the product workflow, not a claim it was performed
for this documentation-only migration.

## Review coverage corrections

The source-to-spec check after review also explicitly preserves:

- RELEASE.md 99–104, 179–189; AGENT_RELEASE.md 11–16; PRODUCTION.md 174–177; scripts/release.py 194: canonical https://cdn.tilr.dev app/server feeds and version/build/architecture DMG names, including -preview (release-publishing: Immutable publication with feed last; Independent signed server publication; release-packaging: Architecture-specific signed artifacts; Build switches and preview isolation).
- RELEASE.md 179–189 and scripts/publish.py 268–271, 346–351: exact appcast Cache-Control, published-feed byte comparison, published.json success record and local appcast copy (release-publishing: Immutable publication with feed last).
- CLAUDE.md 77 and Sources/Tilr/Config.swift 533: browser.automation_private_input=true and unavailable hover when disabled, preserving public click/DOM scroll (native-plugins: Browser reporting and automation configuration).
- PRODUCTION.md 215–217: current shared app/server release key and CryptoKit runtime verification (release-publishing: Independent signed server publication; local-server: Authenticated and compatible replacement).
- RELEASE.md 74, 155 and native-plugins/README.md 13–21: Sparkle pin/controller/menu, audio provider scope and named JavaScript aliases/module (release-publishing: Application updater lifecycle and consent; native-plugins: Independent plugin packages and ABI; Session and host isolation).

These corrections update this task's own ADDED baseline and archived deltas together; no requirement already present in dev is modified.
