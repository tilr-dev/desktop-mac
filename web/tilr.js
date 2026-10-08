// Helpers plugins import as 'tilr' (see the import map in index.html). No top-level await here:
// runtime.js is still evaluating when plugins load, so this module must stand on its own.
import { Service } from 'cordis'

/** Adopts `sheet` into a document or shadow root; returns the undo. */
export function adopt(root, sheet) {
  root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet]
  return () => { root.adoptedStyleSheets = root.adoptedStyleSheets.filter(s => s !== sheet) }
}

/**
 * The `theme` service: one CSSStyleSheet with the tokens (--bg, --accent, …) and the base
 * classes (.tile, button, …) that plugins style themselves with. The document adopts it
 * while the theme plugin is alive; shadow roots get it through `ctx.theme.attach(root)`.
 */
export class Theme extends Service {
  constructor(ctx, { name, sheet }) {
    super(ctx, 'theme')
    this.variant = name
    this.sheet = sheet
    ctx.effect(() => adopt(document, sheet), 'theme sheet')
  }

  /** Gives a shadow root the theme's classes. The effect belongs to the calling plugin. */
  attach(root) {
    this.ctx.effect(() => adopt(root, this.sheet), 'theme.attach()')
  }
}

/**
 * Makes a theme plugin out of a CSS file: `export default theme(import.meta.url, './my.css')`.
 * The CSS is fetched (not imported) on every start, so saving it hot-reloads the theme.
 * Only one theme runs at a time: the host switches the previous one off (see `provide`).
 */
export function theme(base, css) {
  const name = /\/plugins\/([^/]+)\//.exec(base)?.[1] ?? 'theme'
  return {
    name,
    provide: 'theme',
    async apply(ctx) {
      const response = await fetch(new URL(css, base), { cache: 'no-store' })
      if (!response.ok) throw new Error(`${css}: ${response.status}`)
      const sheet = new CSSStyleSheet()
      sheet.replaceSync(await response.text())
      ctx.plugin(Theme, { name, sheet })
    },
  }
}
