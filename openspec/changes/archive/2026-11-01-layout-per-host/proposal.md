# Runtime host identity

## Why
Pages in separate native windows share website storage but need independent layout state. The runtime needs the window's durable identity before its scripts execute.

## What Changes
- Expose the native host UUID and deterministic legacy-layout owner at document start.
- Preserve metadata across reload and workspace restoration.
- Define the standalone-browser fallback without changing application origins or shared settings storage.

## Impact
Native window creation, runtime bootstrap and layout persistence gain a common host identity contract.
