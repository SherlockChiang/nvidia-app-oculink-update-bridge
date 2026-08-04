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

Official release packages require valid, timestamped Authenticode signatures
from one expected publisher on the Windows launcher, service executable,
maintenance manifest, and every packaged PowerShell installer/module file. The
signed release workflow also publishes GitHub/Sigstore provenance attestations
for the ZIP and checksum sidecar. Official signed packages do not contain the
legacy unsigned `.cmd` entry points.

The launcher is a self-contained x64 NativeAOT executable, so adjacent CLR
configuration, startup-hook, or profiler inputs cannot run before its trust
checks. Its PE dependent-load policy and every dynamic P/Invoke restrict DLL
resolution to System32 before managed entry. It is `asInvoker`; status checks remain unprivileged. Setup, repair,
and uninstall restart the same launcher through Windows `runas`, so UAC can
identify its Authenticode publisher. A read-only, identity-checked lease prevents
that launcher path from being renamed, overwritten, or replaced between trust
validation and elevated process creation. The elevated child copies only a compiled
allowlist into a random Administrator/SYSTEM-only ProgramData staging
directory, then rechecks WinVerifyTrust, the common signer, file lengths, and
SHA-256 values from the signed maintenance manifest. WinVerifyTrust checks
revocation for the signer chain (excluding the root) and fails closed when
revocation status cannot be established. Only then does it invoke
the absolute System32 Windows PowerShell with a sanitized system search path.
The staging directory is removed after success or failure.

Unsigned CI/local builds deliberately remain usable for controlled testing,
but only for deterministic self-tests and read-only status inspection. The
launcher refuses privileged maintenance when unsigned. A present-but-invalid
or untrusted signature fails closed; it cannot fall back to unsigned
development mode. Unsigned builds must not be redistributed as end-user
releases that claim a verified publisher or the signed-launcher maintenance
boundary.

An explicitly marked unsigned prerelease may include the fixed six-file batch
entry-point set under `installer` for advanced testing. That mode is mutually
exclusive with signature-required packaging. Its `.cmd` files launch unsigned
PowerShell maintenance scripts outside the NativeAOT launcher's signature,
secure-staging, and same-publisher checks; the UAC dialog identifies Windows
PowerShell rather than this project. Both the batch host and script
self-elevation resolve the fixed Known Folder/System32 Windows PowerShell, not
the current directory or `PATH`. The signer rejects preview markers, flags, and
`.cmd` files before loading a certificate. The ZIP warning, SHA-256 sidecar,
exact package allowlist, and CI negative tests reduce accidental misuse but do
not provide publisher trust.
