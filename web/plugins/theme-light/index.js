// A second theme to switch to. Same contract as plugins/theme (tokens + base classes), its own
// look. Switching it on switches the other theme off.
import { theme } from 'tilr'

export default theme(import.meta.url, './light.css')
