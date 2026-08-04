# Installation

This archive contains only the Windows runtime, required maintenance files,
license, build metadata, and integrity information. It contains no NVIDIA
driver payloads, repository source, tests, changelog, or maintainer documents.

## Unsigned preview

If `UNSIGNED-PREVIEW.txt` is present, this is an advanced-user prerelease with
no trusted Authenticode publisher:

1. Verify the ZIP against the adjacent `.zip.sha256` file.
2. Extract the entire ZIP. Do not run files from an archive preview window.
3. Read `UNSIGNED-PREVIEW.txt` and review the PowerShell scripts.
4. From a normal, non-elevated session, run `installer\Setup.cmd`.

`Setup.cmd` automatically selects a fresh install, v3 migration, or v4 repair.
Use `installer\Status.cmd` to inspect the installation and
`installer\Uninstall-NvidiaAppOculinkShim.cmd` to remove it. UAC identifies
Windows PowerShell, not this project, for this unsigned path.

## Trusted signed package

If `UNSIGNED-PREVIEW.txt` is absent, verify the Authenticode publisher and the
published ZIP checksum, then run `NvidiaAppOculinkUpdateBridge.exe`.

The bridge changes only NVIDIA App driver-metadata discovery. NVIDIA App still
selects, downloads, verifies, and installs official NVIDIA drivers.

Project releases:
https://github.com/SherlockChiang/nvidia-app-oculink-update-bridge/releases
