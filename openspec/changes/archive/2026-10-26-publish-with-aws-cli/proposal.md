# Publish to the CDN with the AWS CLI

## Why
tilrd uploads to the R2 bucket with the AWS CLI and R2 S3 keys; desktop-mac used Wrangler with Node and an API token. One upload method for both, without Node and Wrangler (Dan, 2026-10-26).

## What Changes
- Uploads are `aws s3 cp` to the R2 endpoint with content type and cache control; the access check is `aws s3api head-bucket`.
- Node and Wrangler are no longer publication prerequisites; the CI publish job takes `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` instead of a Cloudflare token.

## Impact
- Specs: release-publishing (credential preflight, release from CI), release-packaging (one-command server release).
- The release Mac keeps the R2 keys in an AWS CLI profile.
