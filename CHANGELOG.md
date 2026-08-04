# Changelog

All notable changes to this project are documented in this file. Versions use
[Semantic Versioning](https://semver.org/).

## Unreleased

## 4.1.0-rc.2 - 2026-08-04

### Changed

- Reduce the unsigned preview to three user-facing lifecycle commands: setup,
  status, and uninstall. Setup continues to select fresh install, v3 migration,
  or v4 repair automatically.
- Replace repository documentation inside the installer ZIP with one concise,
  package-specific English installation guide.
- Enforce exact minimal package sets: 15 files for launcher-based packages and
  19 files for the explicit installer-batch preview.

### Removed

- Remove repository source documentation, changelog, security policy, and
  translated README from installer ZIPs.
- Remove the retired `legacy-v3` source snapshot and three redundant internal
  action batch wrappers from the active tree. The old implementation remains
  available from Git history and the `v4.1.0-rc.1` tag.

### Security

- Keep all nine launcher maintenance inputs and the signed-manifest trust model
  intact while tightening the public ZIP allowlist.
- Continue to reject any preview package in the signing path and require all 11
  signable preview files to remain consistently unsigned.

## 4.1.0-rc.1 - 2026-08-04

### Added

- Add a self-contained x64 NativeAOT Win11 GUI launcher for setup/upgrade,
  status, repair, and uninstall; maintenance requests UAC through the same
  signable executable without a CLR pre-main loading surface.
- Add a signed maintenance manifest that binds the exact privileged file set
  to its package version, lengths, and post-signing SHA-256 values.
- Add an explicit unsigned installer-batch preview package mode with six
  legacy `.cmd` entry points under the `installer` subdirectory.

### Changed

- Run the expensive ephemeral Authenticode pipeline self-test on scheduled and
  manually dispatched CI runs while keeping signed releases fully gated.
- Give signed releases enough time for Windows trust validation, while bounding
  the certificate-bearing step separately and cleaning its temporary PFX.
- Keep unsigned `.cmd` entry points out of normal and signed ZIPs; the explicit
  preview mode includes them only under `installer` with a prominent warning.
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
- Make installer-batch preview mode mutually exclusive with signature-required
  packaging, make the signer reject preview markers/flags/commands before it
  loads a certificate, require an exact batch allowlist, and test positive and
  fail-closed package paths in CI. Batch entry points and their self-elevation
  resolve the fixed System32 Windows PowerShell instead of `PATH`; they still
  remain outside the signed launcher trust boundary and are for advanced
  preview testing only.

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
