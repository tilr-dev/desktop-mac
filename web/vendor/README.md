# vendor

Browser builds of the plugin runtime, copied as-is (MIT, see LICENSE):

- `cordis.js` — `@deepseek-ai/cordis` 4.0.1, from `deepseek-harness/vendor/cordis/lib/index.js`
  (commit 99f6f02fec, 2026-08-17)
- `cosmokit.js` — `@deepseek-ai/cosmokit` 1.8.2, its only dependency

The import map in `index.html` maps `cordis` and `@deepseek-ai/cosmokit` here, so plugins
write `import { Service } from 'cordis'`. To update: copy the two `lib/index.js` files again.
