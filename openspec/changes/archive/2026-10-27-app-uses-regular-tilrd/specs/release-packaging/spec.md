## MODIFIED Requirements

### Requirement: Independently built server artifacts
release_server.py SHALL acquire signed and notarized macOS tilrd and tilr from the same pinned upstream GitHub Release independently from application releases, writing completion receipts only after verification of both executables.

#### Scenario: Build a server
- **WHEN** the pinned version is requested
- **THEN** both architectures are acquired by default, --arch selects one, --channel beta selects the independent beta feed and --min-app-build/--max-app-build constrain compatibility
- **AND** tilr-v<version>-<target>.tar.gz from tilr-dev/tilrd has its published SHA-256 verified before extracting either executable
- **AND** both binaries have their architecture, Developer ID signature, expected Apple team, secure timestamp and matching version verified before completion
- **AND** a missing client, bad checksum, unsafe archive, unexpected architecture, signature or version stops acquisition without a completed receipt or source-build fallback
- **AND** no Rust, Zig, protoc, source checkout or Apple signing/notarization credentials are required
- **AND** fetch_server.py exits with code 1 on missing or invalid upstream assets
- **AND** server-release.json pins the upstream version and protocol; completion metadata retains an independent feed build number
- **AND** TILR_SERVER_RELEASE_ROOT may supply completed artifacts, which are verified before use
- **AND** application packaging copies both executables and exact server manifest without compiling, stripping or re-signing either executable
