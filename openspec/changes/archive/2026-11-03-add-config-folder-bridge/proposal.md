## Why
Page plugins need to read and save their own files in the selected application config directory and observe external edits.

## What Changes
- Add the trusted tilrConfig read/write bridge with filename validation and protected application settings.
- Forward direct config-folder file changes to every trusted application page.

## Impact
Configuration, page bridges and config-folder watching. Existing configuration reload behavior remains.
