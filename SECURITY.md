# Security policy

## Supported versions

Only the latest published v4 release is supported. The `legacy-v3` directory is
retained for investigation history and migration compatibility; it is not the
recommended deployment.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** / private vulnerability
reporting feature. Do not open a public issue for a vulnerability that could
enable local privilege escalation, unauthorized configuration modification,
request smuggling, or bypass of the loopback/origin/path restrictions.

Include the affected version, Windows build, NVIDIA App version, reproduction
steps, and the smallest useful diagnostic excerpt. Remove loopback URL tokens,
cookies, authorization headers, usernames, and unrelated machine information.

## Security boundary

The bridge:

- runs as `NT AUTHORITY\LocalService`, not SYSTEM or Administrator;
- binds only to `127.0.0.1`;
- forwards only allowlisted NVIDIA metadata-controller paths;
- accepts browser-origin traffic only from the exact `https://nvfile` origin;
- connects to the fixed `https://gfwsl.geforce.com` upstream using normal TLS
  validation;
- limits request and response sizes;
- never downloads, serves, modifies, verifies, or installs a driver package.

The URL token is a routing and web-request/CSRF barrier. It is not intended to
protect against a malicious native process running as the same Windows user.

Installation and repair require a user-approved UAC prompt because NVIDIA App
configuration and Windows Service registration are protected system changes.
The continuously running service cannot rewrite its own binary/configuration or
NVIDIA App configuration.

Official release packages require valid Authenticode signatures on the service
executable and all packaged PowerShell installer/module files. The signed
release workflow also publishes GitHub/Sigstore provenance attestations for the
ZIP and checksum sidecar. The `.cmd` files are thin convenience launchers and
are covered by the attested ZIP and SHA-256 manifest; Windows does not support
Authenticode signing for batch files.
