# Drop the app-managed server feed

## Why
Tilr delegates server updates to tilrd update. The desktop release no longer has a consumer for its signed server feed.

## What Changes
- Remove server feed publication, compatibility ranges and feed-only numbering from local commands and CI.
- Keep verified upstream acquisition, exact bundled executables and the server release pin.
- Keep the server release wrapper for acquisition, inspection and printing the pin.
- Update operator documentation and release tests.

## Impact
Release packaging, release publishing and security reporting scope. Application Sparkle publication is unchanged.
