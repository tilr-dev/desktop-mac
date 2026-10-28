# Align server release requirement and scenario titles with acquisition

## Why
Server release requirements and scenarios describe acquiring and verifying signed upstream artifacts, but their names still refer to source builds or publication. A scenario for a removed source option adds no current product behavior.

## What Changes
- Replace "Independently built server artifacts" with "Verified upstream server artifacts" and "One-command independent server release" with "One-command upstream server acquisition"; behavior is unchanged.
- Rename acquisition, verification, inspection and app-pin scenarios to match their bodies.
- Remove the obsolete source-option rejection scenario while retaining acquisition without a local checkout.

## Impact
- Affected specs: release-packaging.
- Affected code: none.
