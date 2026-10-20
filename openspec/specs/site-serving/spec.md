# site-serving Specification

## Purpose
TBD - created by archiving change bootstrap-desktop-mac. Update Purpose after archive.

## Requirements

### Requirement: App source selection and isolated origins
Tilr SHALL load local app folders under distinct `tilr://<name>/` origins, or a single development URL supplied by `--url URL` or `TILR_URL`.

#### Scenario: Select folders
- **WHEN** Tilr resolves apps
- **THEN** `--site DIR` selects one default app, otherwise a development URL selects one default app, otherwise nonempty `apps` supplies ordered name/site pairs, otherwise `site` selects the default app (default `apps/default`)
- **AND** `--url` takes precedence over `TILR_URL`; a development URL is loaded instead of local folder contents
- **AND** installer --site or TILR_SITE selects the install destination, while runtime --site is relative to the current working directory; configured site paths are relative to config and no legacy site migration is performed
- **AND** app names become lowercase ASCII alphanumeric hosts, other characters become hyphens, surrounding hyphens are trimmed and an empty slug becomes `app`; distinct origins separate page storage

#### Scenario: Empty app directory
- **WHEN** a selected folder lacks `index.html`
- **THEN** Tilr creates missing parent folders without overwriting contents and shows a bundled placeholder naming the site and config paths

#### Scenario: Install and load a custom interface
- **WHEN** a recipient installs Tilr
- **THEN** macOS 14+ is required without a Node/npm/Homebrew/Xcode prerequisite; the bundle contains a welcome page and local server but no preinstalled web/plugin workspace
- **AND** the user drags Tilr from the DMG into Applications and launches that copy; the welcome page explains loading a custom index.html folder and preserves site/apps/--site/--url choices

### Requirement: Local asset serving
Tilr SHALL serve local app files with MIME types, directory indexes and extensionless SPA fallback while rejecting parent-directory traversal components.

#### Scenario: Request a local path
- **WHEN** a page requests `tilr://<host>/<path>`
- **THEN** its own handler resolves paths relative to its configured root, directories serve their `index.html`, and unknown extensionless paths fall back to the root `index.html`
- **AND** missing files fail, literal `..` path components are refused, and successful responses contain Content-Type, Content-Length and Cache-Control no-store
- **AND** responses contain the entire file; HTTP Range/206 media seeking is not supported
- **AND** disk reads run off the main queue and stopped WebKit scheme tasks receive no subsequent callbacks

### Requirement: Site reload and page lifecycle
Tilr SHALL watch loaded app folders and refresh changed content without mixing page navigation state or leaking page-owned resources.

#### Scenario: Source changes
- **WHEN** a loaded app folder changes
- **THEN** changes are gathered using `watch.latency` (default 0.2 seconds); changes confined to `plugins/` use the page's plugin hot-reload entry point when available, otherwise the page reloads
- **AND** changing the configured site updates the handler root and navigates loaded tabs immediately; unloaded tabs pick it up when first loaded
- **AND** changing the app itself replaces its web view to reset navigation history while retaining its configured data store and bridges
- **AND** navigation/reload closes SSH agent streams and releases or temporarily parks page-owned browser views for adoption; native audio sessions survive page navigation
