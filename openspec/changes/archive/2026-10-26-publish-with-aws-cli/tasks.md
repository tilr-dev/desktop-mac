## Implementation

- [x] Upload with `aws s3 cp` to the R2 endpoint in the app and server publishers.
- [x] Check bucket access with `aws s3api head-bucket`; drop the Node and Wrangler checks.
- [x] Pass R2 keys to the CI publish job; extend the workflow contract.
- [x] Test the upload command and the bucket check; update the release docs.
