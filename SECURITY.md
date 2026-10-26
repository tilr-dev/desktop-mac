# Security policy

Report vulnerabilities privately through GitHub's
[security advisories](https://github.com/tilr-dev/desktop-mac/security/advisories/new),
not in public issues. Include the Tilr version (Tilr → About), macOS version, architecture
and steps to reproduce.

The update channel matters most: a flaw that lets someone serve, replace or sign a Tilr
update (the Sparkle feed at `cdn.tilr.dev`, its EdDSA signatures, or the bundled
`tilrd` feed) is in scope, as is anything that escapes the page sandbox into native
code (the page bridge, native plugins, Tilr Control).

Only the latest release receives fixes.
