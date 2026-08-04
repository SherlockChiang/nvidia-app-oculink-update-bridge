# NVIDIA App OCuLink Update Bridge

[简体中文](README.zh-CN.md) | English

This repository takes over the verified `nvidia-app-driver-shim` experiment and
turns it into a maintainable Windows 11 background service.

The bridge fixes update *discovery* for a desktop NVIDIA GPU connected to a
laptop through OCuLink. NVIDIA App still selects, downloads, verifies, and
installs the official package. The bridge never serves a driver binary.

This is an independent, unofficial project. It is not affiliated with,
endorsed by, or supported by NVIDIA Corporation. NVIDIA, GeForce, and NVIDIA
App are trademarks of their respective owners.

## Current status

- The inherited v3 implementation is preserved under [`legacy-v3`](legacy-v3).
- A dependency-free .NET service implementation lives under
  [`src/NvidiaAppOculinkShim`](src/NvidiaAppOculinkShim). It compiles without
  third-party NuGet packages and includes direct Windows SCM integration.
- The development machine was transactionally migrated from v3, fully
  uninstalled back to NVIDIA's official configuration, and then reinstalled
  through the native v4 first-install path. All three paths passed live checks.
- `NvidiaAppOculinkUpdateBridge.exe` provides one signed Windows menu for
  setup/upgrade, status, repair, and uninstall. Status remains
  non-administrator; maintenance requests one UAC approval only when needed.
- The installed service runs as `NT AUTHORITY\LocalService` (`S-1-5-19`),
  starts automatically, and recovered under SCM with a new PID after a forced
  process termination.
- NVIDIA GPU IDs are derived from connected Win11 PnP devices; the original
  development GPU ID is no longer hard-coded in product validation.

Read [`docs/workflow.zh-CN.md`](docs/workflow.zh-CN.md) for the request flow and
[`docs/product-architecture.zh-CN.md`](docs/product-architecture.zh-CN.md) for
the Win11 product design and release gates. Repository maintainers should also
read the [signed GitHub release guide](docs/github-release.zh-CN.md).

## Win11 package

Build output is an x64 ZIP. Both the service and native Windows launcher are
self-contained; users do not install a separate runtime. After extraction:

1. Double-click `NvidiaAppOculinkUpdateBridge.exe` and choose **Set up or
   upgrade**.
2. Approve the launcher UAC prompt. A signed release shows the project's code
   signing publisher instead of an unsigned batch/PowerShell host.
3. Use NVIDIA App normally. Its background/manual metadata checks now pass
   through the LocalService bridge.
4. Open the launcher at any time for a status check without elevation.
5. After an NVIDIA App upgrade, choose **Set up or upgrade** again; it selects
   the schema-aware repair path. Choose **Uninstall** to restore NVIDIA's
   original endpoint and refresh timestamp.

CI artifacts and locally built executables are intentionally **not
Authenticode signed**. They are fit for controlled testing, not broad public
distribution; the launcher permits self-tests and status inspection but refuses
privileged maintenance when unsigned. The `Signed release` workflow refuses to create a GitHub Release
unless the launcher, service executable, signed maintenance manifest, and every
packaged PowerShell installer/module have valid matching Authenticode
signatures. It also creates GitHub/Sigstore provenance attestations for the ZIP
and its checksum file.

For GitHub Releases, verify both the published SHA-256 manifest and the
Authenticode signature before approving UAC. Do not install binaries attached
to issues or supplied by third parties.

The launcher elevates the same signed executable, copies an exact maintenance
allowlist to an Administrator/SYSTEM-only staging directory, and revalidates
WinVerifyTrust, signer identity, version, and signed-manifest hashes before it
starts the fixed system Windows PowerShell. Native static/dynamic DLL loading is
System32-scoped, and a file-identity-checked read lease prevents replacement of
the verified launcher before UAC creates the elevated child. Public packages do
not include the legacy `.cmd` entry points.

## Developer commands

```powershell
dotnet build .\NvidiaAppOculinkShim.slnx --configuration Release
dotnet run --project .\src\NvidiaAppOculinkShim --configuration Release --no-build -- --self-test
.\tests\Invoke-LauncherSelfTest.ps1
.\tests\Invoke-IntegrationTest.ps1 -Configuration Release
.\build\Publish-Package.ps1
```

Normal console/service execution reads `config.json` beside the executable, or
an explicit path supplied as `--config <path>`. SCM mode is selected with
`--service`.

## Security boundary

The listener binds only to `127.0.0.1`, requires a random URL token,
permits only known NVIDIA metadata-controller paths, and accepts browser-origin
requests only from `https://nvfile`. Upstream traffic is pinned to
`https://gfwsl.geforce.com` with standard TLS certificate validation.

The token is a web-request routing/CSRF barrier, not a defense against a
malicious native process running as the same Windows user. Security does not
depend on the token alone: path allowlisting, exact browser Origin checks,
loopback binding, fixed HTTPS upstream, payload limits, and the LocalService
write boundary are all enforced independently.

The service contains no telemetry. Diagnostic JSONL logs remain under the
protected local ProgramData runtime directory.

## License

[MIT](LICENSE)
