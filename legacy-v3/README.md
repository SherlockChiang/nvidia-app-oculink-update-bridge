# NVIDIA App OCuLink Driver Metadata Shim

This local shim restores NVIDIA App's own **Drivers > Check for updates**
workflow for a desktop NVIDIA GPU attached to a laptop through OCuLink. The
current verified result is the official Game Ready Driver **610.88**.

The App's native updater currently sends the laptop motherboard flag
(`iLp=1`) and an over-specific Windows code (`osC=10.0.26200`). NVIDIA's
official metadata endpoint returns no candidate for that combination. The same
request with `iLp=0` and `osC=10.0` returns the current desktop driver.

The original profile-only redirect was not enough for the visible refresh
button: that path is handled by `NvBackend64.dll`, which reads
`NvLocalizedConfig`. An additional NVIDIA URL-parser defect rejects a
loopback URL with an explicit port. NVIDIA leaves `:17886` in the server name
passed to WinHTTP, and `WinHttpOpenRequest` then fails locally with error
12005 before sending a packet. The v3 upgrade therefore redirects the
existing `grd`/`crd` profiles and the localized GFWSL setting to the same
tokenized `http://127.0.0.1/...` URL on implicit HTTP port 80.

The shim:

- listens only on `127.0.0.1:80` behind a random token (it is not reachable
  through the machine's LAN addresses);
- accepts only fixed NVIDIA metadata-controller paths;
- accepts browser requests only from the exact NVIDIA App origin
  `https://nvfile`, with credentialed CORS and Private Network Access
  preflight support;
- normalizes only the two proven-bad classifications (`iLp` and `osC`) and
  derives the matching Windows build field (`osB`);
- preserves the GPU ID, installed/requested version (`GFPV`), driver branch,
  and every other request field;
- retrieves metadata from the fixed upstream
  `https://gfwsl.geforce.com` with normal TLS validation;
- never proxies, downloads, modifies, or installs a graphics-driver package.

NVIDIA App remains responsible for selecting the release, downloading it
directly from NVIDIA's CDN, validating it, and installing it. The App's
existing SHA-256 and NVIDIA/Microsoft signer checks remain unchanged.

The installed code, configuration, state, and rollback copies live in the
protected `C:\ProgramData\NVIDIAAppOCuLinkDriverShim` directory. The helper
runs as Windows `LocalService`—not as Administrator or SYSTEM—through a
startup task. Only its runtime log/PID directory is writable by that service.

## Upgrade the existing installation

This is the required path for a machine that already has the earlier
profile-only shim:

1. Double-click `Upgrade-NvidiaAppDriverShim.cmd`.
2. Approve the Windows UAC prompt and wait for the completion message.
3. In the relaunched NVIDIA App, open **Drivers** and click
   **Check for updates**.

The upgrade transactionally backs up the helper, helper configuration,
`component_profiles.json`, and `LocalizedConfig.json`. It installs the v3
helper, migrates the listener from port 17886 to implicit port 80, performs
live recommendation/details and CORS/PNA checks, updates both NVIDIA metadata
paths, and defers the localized cache's root `configTimestamp` by one year
before reloading the NVIDIA configuration service. The timestamp deferral
prevents `NvLocalizedConfig` from immediately refreshing the cache and
replacing the loopback endpoint during service startup. If any check fails,
the prior port, helper, NVIDIA files, state, and service are restored.

While the shim is installed, NVIDIA App's remote localized-configuration
refresh is deferred; the complete existing cached configuration remains
available to the App. This does not defer driver metadata checks, which go
through the loopback helper to NVIDIA on every App refresh. An NVIDIA App
reinstall or the one-year expiry may require running the upgrade again.

Do not use the installer merely to fetch 610.88. This package restores the
App's update function; it does not download or install the driver itself.

## First installation

If the protected shim directory does not exist yet, first double-click
`Install-NvidiaAppDriverShim.cmd`, then run
`Upgrade-NvidiaAppDriverShim.cmd` to enable the NVIDIA App UI/backend path.
Each launcher requests elevation only for its protected system changes.

## Verify

After the upgrade, run `Test-NvidiaAppDriverShim.ps1` from PowerShell. It fails
unless all of the following are true:

- protected state reports an installed v3 helper and UI redirect;
- the protected helper configuration uses port 80, while the NVIDIA-facing
  URL contains no explicit port (the required workaround for the NVIDIA
  WinHTTP parsing defect);
- the live `NvLocalizedConfig` GFWSL server and both App profiles point to the
  tokenized loopback URL;
- the live root `configTimestamp` exactly matches the recorded value and is
  still at least seven days in the future;
- the original configuration backup and live patched configuration match
  their recorded SHA-256 hashes;
- health/PID and the `LocalService` helper identity are consistent;
- an exact `https://nvfile` credentialed CORS/PNA preflight succeeds;
- NVIDIA recommends 610.88 for the OCuLink GPU;
- a details request with `GFPV=610.88` returns a complete NVIDIA record,
  including ID, release date, `clientUX`, and an HTTPS NVIDIA download URL for
  610.88.

The source-tree-only `selftest.mjs` performs the same metadata/CORS checks
against an isolated test helper. It also verifies that an untrusted browser
origin receives HTTP 403 and that unrelated paths remain blocked.

## Uninstall

Double-click `Uninstall-NvidiaAppDriverShim.cmd`. The uninstaller restores the
exact protected backups when the NVIDIA files are otherwise unchanged. If
NVIDIA App updated a catalog/configuration in the meantime, it restores only
the shim-owned endpoint and timestamp fields (only while they still equal the
recorded shim values), so unrelated NVIDIA changes are preserved. Restoring
the original timestamp lets `NvLocalizedConfig` resume its normal official
refresh schedule. The uninstaller then reloads the NVIDIA configuration
service.

The helper log is
`C:\ProgramData\NVIDIAAppOCuLinkDriverShim\runtime\shim.log`. A real NVIDIA App
refresh should add a `driver-recommendation` entry with
`browserOrigin: "https://nvfile"` or a native backend request, followed by a
`driver-details` entry for the recommended `GFPV`.
