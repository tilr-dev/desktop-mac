# Configure daemon updates independently

## Why
The daemon owns its update channel in server.toml. Application RC preferences must only select the application update feed.

## What Changes
- Invoke the selected daemon update command without a channel argument at launch and on demand.
- Keep Receive RC versions scoped to Sparkle.

## Impact
- Local Server update integration and application update preferences.
- Local Server specification and integration fixtures.
