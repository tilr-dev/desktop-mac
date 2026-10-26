# performance Specification

## Purpose
Define demand-driven performance diagnosis, controlled export and guarded optional platform features.

## Requirements

### Requirement: Demand-driven performance access
Tilr SHALL accept Performance bridge requests only from the trusted top-level app origin and sample only Tilr and that tab's WebContent processes on demand.

#### Scenario: Sample and reset
- **WHEN** the app requests a sample or reset
- **THEN** native CPU/memory sampling does not start a background polling timer and reset clears sampling baselines
- **AND** browser pages, subframes and mismatched origins are denied; unavailable WebContent PID discovery is reported without including unrelated processes

### Requirement: Memory diagnosis
Tilr SHALL provide footprint, squeeze and inspector through the Performance bridge and Control with explicit availability and scope.

#### Scenario: Diagnose memory
- **WHEN** footprint is requested
- **THEN** `/usr/bin/footprint -j` runs off the UI thread with `debug.footprint_timeout` and reports per-process role/scope and malloc, graphics, js, jit and other bytes
- **WHEN** squeeze is requested
- **THEN** the `org.WebKit.lowMemory` notification is system-wide, affecting other WebKit applications as well as Tilr
- **WHEN** inspector is requested
- **THEN** guarded WebKit inspection opens the requested tab or returns `shown: false` with a reason and Safari Develop as the public alternative

### Requirement: Debug recording and file dialogs
Tilr SHALL expose debug status and bounded recording/export operations without silently interfering with a page-owned recording.

#### Scenario: Record and export
- **WHEN** Control requests debug status or recording
- **THEN** status reports whether the page collector exists, its mechanism/activity, recording state, directory and high-refresh availability; a missing collector has an explicit reason
- **AND** an already recording page is rejected; completed control recordings are saved under the configured debug directory with a summary
- **AND** Performance save/open dialogs allow one active dialog, enforce requested byte limits and UTF-8, sanitize suggested filenames and write atomically; navigation cancels a pending dialog

### Requirement: Optional private API guards
Tilr SHALL use public APIs by default and permit optional private APIs only with runtime symbol/class/selector/result checks and an honest unavailable result or public fallback, without requiring SIP changes.

#### Scenario: Unsupported system
- **WHEN** desktop movement, native hover, WebContent PID lookup, high-refresh preferences or inspector APIs are unavailable
- **THEN** the feature reports unavailable or uses its documented public fallback rather than invoking an absent API
- **AND** hover unavailability does not disable public click/DOM scroll, high-refresh unavailability leaves the normal 60 Hz preference and logs once, and desktop movement verifies exact desktop membership before reporting success
- **AND** `web.high_refresh_rate` and `debug.inspectable` are applied at tab creation/launch; the refresh switch removes WebKit's cap where supported without promising an unsupported display rate
