# Changelog

All notable changes to this project are documented in this file. Versions use
[Semantic Versioning](https://semver.org/).

## Unreleased

### Changed

- Run the expensive ephemeral Authenticode pipeline self-test on scheduled and
  manually dispatched CI runs while keeping signed releases fully gated.

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
