# Changelog

All notable changes to this project are documented in this file. Versions use
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Add a self-contained x64 NativeAOT Win11 GUI launcher for setup/upgrade,
  status, repair, and uninstall; maintenance requests UAC through the same
  signable executable without a CLR pre-main loading surface.
- Add a signed maintenance manifest that binds the exact privileged file set
  to its package version, lengths, and post-signing SHA-256 values.

### Changed

- Run the expensive ephemeral Authenticode pipeline self-test on scheduled and
  manually dispatched CI runs while keeping signed releases fully gated.
- Give signed releases enough time for Windows trust validation, while bounding
  the certificate-bearing step separately and cleaning its temporary PFX.
- Remove unsigned `.cmd` entry points from public ZIPs; they remain in source
  only for legacy development workflows.
- Return NVIDIA App to the current user session after successful GUI maintenance.

### Security

- Pin signed releases to an expected leaf-certificate thumbprint and reject
  unexpected files in the package allowlist.
- Remove Trusted Root/TrustedPublisher writes from the ephemeral signing test;
  validate the exact WinVerifyTrust untrusted-root result against a temporary
  current-user CA chain, and prove tampered signed files are rejected.
- Before privileged maintenance, copy an exact allowlist to an
  Administrator/SYSTEM-only staging directory and revalidate WinVerifyTrust,
  signer identity, version, and signed-manifest hashes.
- Resolve ProgramData through the Windows known-folder API, atomically create a
  randomized protected staging directory, sanitize the PowerShell environment,
  clean up only ACL-validated stale staging directories, and require whole-chain
  Authenticode revocation checks.
- Force static and dynamic DLL resolution to System32 before managed entry, and
  hold a file-identity-checked read lease across validation and UAC startup so
  the launcher path cannot be replaced after trust is established.

## 4.0.0 - 2026-08-03

### Added

- Dependency-free .NET 10 Windows service with direct Service Control Manager
  integration and `LocalService` isolation.
- One-click setup that selects first install, v3 migration, or v4 repair.
- Non-administrator status check and transactional uninstall.
- Strict loopback HTTP bridge for the NVIDIA GFWSL metadata endpoints.
- Dynamic connected NVIDIA GPU discovery and isolated/live integration tests.
- Self-contained Win11 x64 package generation with SHA-256 manifests.

### Changed

- Replaced the v3 Node.js process and Scheduled Task with a native Windows
  service.
- Preserved the original v3 implementation under `legacy-v3` for migration and
  investigation history.

### Security

- Bound the listener exclusively to `127.0.0.1`.
- Restricted browser requests to the exact `https://nvfile` origin and known
  NVIDIA metadata-controller paths.
- Fixed upstream traffic to `https://gfwsl.geforce.com` with normal TLS
  certificate validation and bounded payload sizes.
- Kept executable, configuration, and NVIDIA App backup files outside the
  continuously running service's write boundary.
- Required Authenticode signatures for the release service executable and all
  packaged PowerShell installer/module files, plus GitHub/Sigstore provenance
  attestations for release assets.
