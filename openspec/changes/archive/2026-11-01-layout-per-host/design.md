# Design

Each shell passes its persisted UUID into its page configuration. A main-frame user script installs `window.__tilrHost` at document start as an immutable property holding a frozen `{ host, primary }` object.

`host` is the native UUID string. `primary` identifies the first valid window of the same application in persisted creation order when the page is created. It remains fixed for the page's lifetime, regardless of focus. New windows use the first existing same-application shell to determine ownership. Application origins and the instance website data store remain shared.

The runtime uses the supplied identity to namespace layout state and permits only the primary page to consume legacy unscoped layout records. Without native metadata, a browser page uses the stable `main` identity. Migration consumes legacy records, so a later primary page cannot import the same layout again.

Reloads and page-view replacements reuse the configuration's user scripts. Workspace restoration recreates the script using the restored shell UUID. Embedded browser views do not receive this main-frame runtime identity.
