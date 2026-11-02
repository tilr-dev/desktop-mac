# Wait for the browser discard report in the native probe

## Why
The probe samples the last report after observing discarded state and WKWebView release. State changes and report delivery are separate events, so that sample can still describe the live view.

## What Changes
- Wait for the matching discarded state report before checking its history fields.
- Exercise delivery after the check starts, delivery before it starts, and unrelated events with controlled event ordering.

## Impact
Browser probe and its regression tests only. The existing native-plugins discard contract remains unchanged; no requirement delta is needed.
