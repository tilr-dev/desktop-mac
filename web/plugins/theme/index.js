// The default theme. All of it is theme.css; this file only turns it into a plugin.
import { theme } from 'tilr'

export default theme(import.meta.url, './theme.css')
