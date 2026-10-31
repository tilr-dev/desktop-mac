# Show release candidate versions in the update panel

## Why
The update panel currently displays the same numeric version for release candidates and stable builds. Users need to identify which release is installed and which one is offered.

## What Changes
- Preserve the verified tag version in separate bundle and appcast display metadata.
- Show that version in Installed and Available, falling back to numeric metadata for older releases.
- Keep Sparkle build comparisons and numeric marketing versions unchanged.

## Impact
Release packaging, publication and the About panel.
