# Design

The signed bundle includes SUPublicEDKey and TilrUpdateFeedSelection=preferences, with no SUFeedURL. The application uses its compiled architecture and a boolean UserDefaults preference to choose the canonical CDN stable or beta appcast on each Sparkle feed delegate invocation. Environment feed overrides are never consulted at runtime. A delegate adapter retains feed selection while forwarding the host’s optional Sparkle callbacks, preserving About status.

Update Settings exposes Receive RC versions (initially false) and Sparkle’s existing automatic check/download preferences. Changing RC preference does not interrupt a running check; the next check reads it.

Publication receipts retain their architecture, feed and verification key. Delta generation continues matching those receipts against the current publication feed. Runtime switching can use the full DMG fallback; cross-channel deltas are unnecessary. New channel-neutral bundles and already completed legacy bundles have distinct metadata validation paths. No promotion command is introduced.
