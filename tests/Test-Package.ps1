[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,
    [Parameter(Mandatory)]
    [string]$ArchivePath,
    [switch]$RequireSignature,
    [switch]$RequireTimestamp,
    [switch]$ExpectInstallerBatchFiles,
    [string]$UntrustedTestRootCertificatePath,
    [string]$ExpectedTestSignerThumbprint
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$package = (Resolve-Path -LiteralPath $PackagePath).Path
$archive = (Resolve-Path -LiteralPath $ArchivePath).Path
$useUntrustedTestRoot =
    -not [string]::IsNullOrWhiteSpace($UntrustedTestRootCertificatePath)
$hasExpectedTestSigner =
    -not [string]::IsNullOrWhiteSpace($ExpectedTestSignerThumbprint)
if ($useUntrustedTestRoot -ne $hasExpectedTestSigner) {
    throw (
        'UntrustedTestRootCertificatePath and ExpectedTestSignerThumbprint ' +
        'must be supplied together.'
    )
}
$normalizedExpectedTestSigner = if ($hasExpectedTestSigner) {
    ($ExpectedTestSignerThumbprint -replace '\s', '').ToUpperInvariant()
} else {
    $null
}
if (
    $hasExpectedTestSigner -and
    $normalizedExpectedTestSigner -notmatch '^[A-F0-9]{40}$'
) {
    throw 'ExpectedTestSignerThumbprint must be a 40-digit SHA-1 thumbprint.'
}
if ($useUntrustedTestRoot -and $RequireTimestamp) {
    throw 'An untrusted test root cannot satisfy timestamped release checks.'
}
$resolvedTestRootCertificatePath = $null
$testSignatureValidator = $null
if ($useUntrustedTestRoot) {
    $resolvedTestRootCertificatePath =
        (Resolve-Path -LiteralPath $UntrustedTestRootCertificatePath).Path
    $repositoryPrefix =
        [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
    if ($resolvedTestRootCertificatePath.StartsWith(
        $repositoryPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The untrusted test root must not be stored inside the repository.'
    }
    $testSignatureValidator =
        Join-Path $PSScriptRoot 'Assert-UntrustedTestSignature.ps1'
    if (-not (Test-Path -LiteralPath $testSignatureValidator -PathType Leaf)) {
        throw 'The untrusted Authenticode test validator is missing.'
    }
    $RequireSignature = $true
}
$reparsePoints = @(
    Get-ChildItem -LiteralPath $package -Recurse -Force |
        Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }
)
if ($reparsePoints.Count -gt 0) {
    throw "The package contains a reparse point: $($reparsePoints[0].FullName)"
}
$installerBatchScripts = [ordered]@{
    'installer\Setup.cmd' = 'Setup.ps1'
    'installer\Status.cmd' = 'Status.ps1'
    'installer\Uninstall-NvidiaAppOculinkShim.cmd' =
        'Uninstall-NvidiaAppOculinkShim.ps1'
}
if (
    $ExpectInstallerBatchFiles -and
    ($RequireSignature -or $RequireTimestamp)
) {
    throw (
        'Installer batch entry points are forbidden in a signed package. ' +
        'Use the NativeAOT launcher for trusted releases.'
    )
}
$requiredFiles = @(
    'NvidiaAppOculinkUpdateBridge.exe',
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.ps1',
    'MaintenanceManifest.ps1',
    'NvidiaAppOculinkShim.Common.psm1',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Setup.ps1',
    'Status.ps1',
    'Test-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.ps1',
    'payload\NvidiaAppOculinkShim.exe',
    'INSTALL.md',
    'LICENSE',
    'BUILD-INFO.txt',
    'SHA256SUMS.txt'
)
if ($ExpectInstallerBatchFiles) {
    $requiredFiles += 'UNSIGNED-PREVIEW.txt'
    $requiredFiles += @($installerBatchScripts.Keys)
}
foreach ($relative in $requiredFiles) {
    $candidate = Join-Path $package $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Package file is missing: $relative"
    }
}
$installGuide = Get-Content -LiteralPath (Join-Path $package 'INSTALL.md') -Raw
foreach ($requiredInstallText in @(
    'It contains no NVIDIA',
    'repository source, tests, changelog, or maintainer documents.',
    'installer\Setup.cmd',
    'installer\Status.cmd',
    'installer\Uninstall-NvidiaAppOculinkShim.cmd',
    'NvidiaAppOculinkUpdateBridge.exe'
)) {
    if ($installGuide.IndexOf(
        $requiredInstallText,
        [StringComparison]::Ordinal
    ) -lt 0) {
        throw "The package installation guide is incomplete: $requiredInstallText"
    }
}
$allowedPackagePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($relative in $requiredFiles) {
    $allowedPackagePaths.Add($relative) | Out-Null
}
$allPackageFiles = @(Get-ChildItem -LiteralPath $package -Recurse -File)
if ($allPackageFiles.Count -ne $allowedPackagePaths.Count) {
    throw 'The package file set does not match the explicit allowlist.'
}
foreach ($file in $allPackageFiles) {
    $relative = $file.FullName.Substring($package.Length + 1)
    if (-not $allowedPackagePaths.Contains($relative)) {
        throw "Unexpected package file: $relative"
    }
}

$buildInfoPath = Join-Path $package 'BUILD-INFO.txt'
$buildInfoLines = Get-Content -LiteralPath $buildInfoPath
$buildVersionLines = @(
    $buildInfoLines |
        Where-Object { $_ -match '^Version: (.+)$' }
)
if ($buildVersionLines.Count -ne 1) {
    throw 'BUILD-INFO.txt must contain exactly one Version line.'
}
$packageVersion = $buildVersionLines[0].Substring('Version: '.Length)
& (Join-Path $repositoryRoot 'build\Assert-SemVer.ps1') `
    -Version $packageVersion |
    Out-Null
$expectedBatchFlag =
    $ExpectInstallerBatchFiles.ToString().ToLowerInvariant()
$batchFlagLines = @(
    $buildInfoLines | Where-Object {
        $_ -eq "Installer-Batch-Files-Included: $expectedBatchFlag"
    }
)
if ($batchFlagLines.Count -ne 1) {
    throw 'BUILD-INFO does not match the expected installer-batch package mode.'
}
$expectedPackageProfile = if ($ExpectInstallerBatchFiles) {
    'installer-batch-preview'
} else {
    'native-launcher'
}
if (@($buildInfoLines | Where-Object {
    $_ -eq "Package-Profile: $expectedPackageProfile"
}).Count -ne 1) {
    throw 'BUILD-INFO does not match the expected package profile.'
}
if (@($buildInfoLines | Where-Object {
    $_ -eq 'Repository-Source-Included: false'
}).Count -ne 1) {
    throw 'BUILD-INFO must exclude repository source.'
}
if (@($buildInfoLines | Where-Object {
    $_ -eq 'Maintainer-Documentation-Included: false'
}).Count -ne 1) {
    throw 'BUILD-INFO must exclude maintainer documentation.'
}
if ($ExpectInstallerBatchFiles) {
    $previewMarkerPath = Join-Path $package 'UNSIGNED-PREVIEW.txt'
    $previewMarker = Get-Content -LiteralPath $previewMarkerPath -Raw
    foreach ($requiredWarning in @(
        'UNSIGNED INSTALLER-BATCH PREVIEW',
        "Version: $packageVersion",
        'This package is not Authenticode signed.',
        'installer\Setup.cmd',
        'Setup automatically selects a fresh install, v3 migration, or v4 repair.',
        'installer\Status.cmd',
        'installer\Uninstall-NvidiaAppOculinkShim.cmd',
        'Do not redistribute this preview as a trusted or production-ready installer.'
    )) {
        if ($previewMarker.IndexOf(
            $requiredWarning,
            [StringComparison]::Ordinal
        ) -lt 0) {
            throw "The unsigned preview warning is incomplete: $requiredWarning"
        }
    }
    foreach ($entry in $installerBatchScripts.GetEnumerator()) {
        $batchContent = Get-Content `
            -LiteralPath (Join-Path $package $entry.Key) `
            -Raw
        $expectedParentFallback =
            'set "bridge_script=%~dp0..\' + $entry.Value + '"'
        foreach ($requiredBatchLine in @(
            'setlocal DisableDelayedExpansion',
            'set "bridge_powershell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"',
            $expectedParentFallback,
            '"%bridge_powershell%" -NoProfile -ExecutionPolicy Bypass -File "%bridge_script%"'
        )) {
            if ($batchContent.IndexOf(
                $requiredBatchLine,
                [StringComparison]::OrdinalIgnoreCase
            ) -lt 0) {
                throw (
                    "Packaged batch entry point is unsafe for $($entry.Value): " +
                    $requiredBatchLine
                )
            }
        }
    }
}
$selfElevatingScripts = @(
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.ps1',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.ps1'
)
foreach ($relative in $selfElevatingScripts) {
    $scriptContent = Get-Content `
        -LiteralPath (Join-Path $package $relative) `
        -Raw
    foreach ($requiredSystemHostToken in @(
        '[Environment+SpecialFolder]::Windows',
        'System32\WindowsPowerShell\v1.0\powershell.exe',
        '-FilePath $systemPowerShell'
    )) {
        if ($scriptContent.IndexOf(
            $requiredSystemHostToken,
            [StringComparison]::Ordinal
        ) -lt 0) {
            throw "$relative does not pin its elevated Windows PowerShell host."
        }
    }
    if ($scriptContent -match '(?i)-FilePath\s+[''"]powershell\.exe') {
        throw "$relative still resolves its elevated host through PATH."
    }
}

$maintenanceRelativePaths = @(
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.ps1',
    'NvidiaAppOculinkShim.Common.psm1',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Setup.ps1',
    'Status.ps1',
    'Test-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.ps1',
    'payload\NvidiaAppOculinkShim.exe'
)
$maintenanceManifestPath = Join-Path $package 'MaintenanceManifest.ps1'
$maintenanceLines = Get-Content -LiteralPath $maintenanceManifestPath
if (@($maintenanceLines | Where-Object {
    $_ -eq '# Manifest-Version: 1'
}).Count -ne 1) {
    throw 'The maintenance manifest version is missing or duplicated.'
}
if (@($maintenanceLines | Where-Object {
    $_ -eq "# Package-Version: $packageVersion"
}).Count -ne 1) {
    throw 'The maintenance manifest package version does not match BUILD-INFO.'
}
if (@($maintenanceLines | Where-Object {
    $_ -eq '# Runtime-Identifier: win-x64'
}).Count -ne 1) {
    throw 'The maintenance manifest runtime identifier is invalid.'
}
$maintenancePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$expectedMaintenancePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($relative in $maintenanceRelativePaths) {
    $expectedMaintenancePaths.Add($relative) | Out-Null
}
$maintenanceEntryCount = 0
foreach ($line in $maintenanceLines) {
    if ($line -eq '# SIG # Begin signature block') {
        break
    }
    if (
        [string]::IsNullOrEmpty($line) -or
        $line -eq '# Manifest-Version: 1' -or
        $line -eq "# Package-Version: $packageVersion" -or
        $line -eq '# Runtime-Identifier: win-x64'
    ) {
        continue
    }
    if ($line -notmatch '^# File-SHA256: ([A-F0-9]{64})  ([0-9]+)  (.+)$') {
        throw "Unexpected maintenance manifest line: $line"
    }
    $maintenanceEntryCount++
    $expectedHash = $Matches[1]
    $expectedLength = [long]$Matches[2]
    $relative = $Matches[3]
    if (-not $maintenancePaths.Add($relative)) {
        throw "Duplicate maintenance manifest path: $relative"
    }
    if (-not $expectedMaintenancePaths.Contains($relative)) {
        throw "Unexpected maintenance manifest path: $relative"
    }
    $candidate = Join-Path $package $relative
    $item = Get-Item -LiteralPath $candidate -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Maintenance manifest target is a reparse point: $relative"
    }
    if ($item.Length -ne $expectedLength) {
        throw "Maintenance manifest length mismatch: $relative"
    }
    $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        throw "Maintenance manifest SHA-256 mismatch: $relative"
    }
}
if (
    $maintenanceEntryCount -ne $maintenanceRelativePaths.Count -or
    @($maintenanceRelativePaths | Where-Object {
        -not $maintenancePaths.Contains($_)
    }).Count -gt 0
) {
    throw 'The maintenance manifest does not cover its exact file allowlist.'
}

$serviceBinary = Join-Path $package 'payload\NvidiaAppOculinkShim.exe'
$serviceInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($serviceBinary)
if (
    [string]::IsNullOrWhiteSpace($serviceInfo.ProductVersion) -or
    $serviceInfo.ProductVersion -ne $packageVersion
) {
    throw (
        'The service product version does not match the package: ' +
        $serviceInfo.ProductVersion
    )
}
$serviceStream = [IO.File]::OpenRead($serviceBinary)
$serviceReader = [IO.BinaryReader]::new($serviceStream)
try {
    if ($serviceReader.ReadUInt16() -ne 0x5A4D) {
        throw 'The service is not a valid PE image.'
    }
    $serviceStream.Position = 0x3C
    $servicePeOffset = $serviceReader.ReadInt32()
    if (
        $servicePeOffset -lt 0x40 -or
        $servicePeOffset -gt $serviceStream.Length - 6
    ) {
        throw 'The service PE header offset is invalid.'
    }
    $serviceStream.Position = $servicePeOffset
    if (
        $serviceReader.ReadUInt32() -ne 0x00004550 -or
        $serviceReader.ReadUInt16() -ne 0x8664
    ) {
        throw 'The service must be an AMD64 PE executable.'
    }
} finally {
    $serviceReader.Dispose()
    $serviceStream.Dispose()
}

$launcherPath = Join-Path $package 'NvidiaAppOculinkUpdateBridge.exe'
$launcherInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($launcherPath)
if (
    [string]::IsNullOrWhiteSpace($launcherInfo.ProductVersion) -or
    (
        $launcherInfo.ProductVersion -ne $packageVersion
    )
) {
    throw (
        'The launcher product version does not match the package: ' +
        $launcherInfo.ProductVersion
    )
}
$launcherStream = [IO.File]::OpenRead($launcherPath)
$launcherReader = [IO.BinaryReader]::new($launcherStream)
try {
    if ($launcherReader.ReadUInt16() -ne 0x5A4D) {
        throw 'The launcher is not a valid PE image.'
    }
    $launcherStream.Position = 0x3C
    $peOffset = $launcherReader.ReadInt32()
    if ($peOffset -lt 0x40 -or $peOffset -gt $launcherStream.Length - 6) {
        throw 'The launcher PE header offset is invalid.'
    }
    $launcherStream.Position = $peOffset
    if ($launcherReader.ReadUInt32() -ne 0x00004550) {
        throw 'The launcher PE signature is invalid.'
    }
    if ($launcherReader.ReadUInt16() -ne 0x8664) {
        throw 'The launcher must be an AMD64 PE executable.'
    }
    $numberOfSections = $launcherReader.ReadUInt16()
    if ($numberOfSections -lt 1 -or $numberOfSections -gt 96) {
        throw 'The launcher PE section count is invalid.'
    }

    $launcherStream.Position = $peOffset + 20
    $optionalHeaderSize = $launcherReader.ReadUInt16()
    $optionalHeaderOffset = $peOffset + 24
    if (
        $optionalHeaderSize -lt 240 -or
        $optionalHeaderOffset + $optionalHeaderSize -gt $launcherStream.Length
    ) {
        throw 'The launcher PE32+ optional header is truncated.'
    }
    $launcherStream.Position = $optionalHeaderOffset
    if ($launcherReader.ReadUInt16() -ne 0x020B) {
        throw 'The launcher must use a PE32+ optional header.'
    }

    $launcherStream.Position = $optionalHeaderOffset + 108
    $dataDirectoryCount = $launcherReader.ReadUInt32()
    if ($dataDirectoryCount -lt 15) {
        throw 'The launcher PE data directories are incomplete.'
    }

    $launcherStream.Position = $optionalHeaderOffset + 112 + (14 * 8)
    $clrHeaderRva = $launcherReader.ReadUInt32()
    $clrHeaderSize = $launcherReader.ReadUInt32()
    if ($clrHeaderRva -ne 0 -or $clrHeaderSize -ne 0) {
        throw 'The launcher contains a CLR header instead of a native AOT image.'
    }

    $launcherStream.Position = $optionalHeaderOffset + 112 + (10 * 8)
    $loadConfigRva = $launcherReader.ReadUInt32()
    $loadConfigSize = $launcherReader.ReadUInt32()
    if ($loadConfigRva -eq 0 -or $loadConfigSize -lt 0x50) {
        throw 'The launcher PE load configuration is missing or truncated.'
    }

    $sectionTableOffset = $optionalHeaderOffset + $optionalHeaderSize
    $loadConfigFileOffset = $null
    $loadConfigRawAvailable = $null
    foreach ($sectionIndex in 0..($numberOfSections - 1)) {
        $sectionOffset = $sectionTableOffset + ($sectionIndex * 40)
        if ($sectionOffset + 40 -gt $launcherStream.Length) {
            throw 'The launcher PE section table is truncated.'
        }
        $launcherStream.Position = $sectionOffset + 8
        $virtualSize = $launcherReader.ReadUInt32()
        $virtualAddress = $launcherReader.ReadUInt32()
        $rawSize = $launcherReader.ReadUInt32()
        $rawOffset = $launcherReader.ReadUInt32()
        $mappedSize = [Math]::Max([uint64]$virtualSize, [uint64]$rawSize)
        if (
            [uint64]$loadConfigRva -ge [uint64]$virtualAddress -and
            [uint64]$loadConfigRva -lt
                ([uint64]$virtualAddress + $mappedSize)
        ) {
            $loadConfigSectionDelta =
                [uint64]$loadConfigRva - [uint64]$virtualAddress
            if (
                $loadConfigSectionDelta + 0x50 -gt [uint64]$rawSize -or
                [uint64]$rawOffset + [uint64]$rawSize -gt
                    [uint64]$launcherStream.Length
            ) {
                throw (
                    'The launcher PE load configuration is not fully backed ' +
                    'by its section raw data.'
                )
            }
            $loadConfigFileOffset =
                [uint64]$rawOffset +
                $loadConfigSectionDelta
            $loadConfigRawAvailable =
                [uint64]$rawSize - $loadConfigSectionDelta
            break
        }
    }
    if (
        $null -eq $loadConfigFileOffset -or
        $loadConfigFileOffset + 0x50 -gt [uint64]$launcherStream.Length
    ) {
        throw 'The launcher PE load configuration cannot be mapped to the file.'
    }

    $launcherStream.Position = [int64]$loadConfigFileOffset
    $declaredLoadConfigSize = $launcherReader.ReadUInt32()
    if (
        $declaredLoadConfigSize -lt 0x50 -or
        $declaredLoadConfigSize -gt $loadConfigSize -or
        [uint64]$loadConfigSize -gt $loadConfigRawAvailable -or
        $loadConfigFileOffset + [uint64]$loadConfigSize -gt
            [uint64]$launcherStream.Length
    ) {
        throw 'The launcher PE load configuration size is inconsistent.'
    }

    $launcherStream.Position = [int64]$loadConfigFileOffset + 0x4E
    if ($launcherReader.ReadUInt16() -ne 0x0800) {
        throw (
            'The launcher must force static dependent DLL loading from ' +
            'System32 (DependentLoadFlags=0x0800).'
        )
    }
} finally {
    $launcherReader.Dispose()
    $launcherStream.Dispose()
}
$manifestPath = Join-Path $package 'SHA256SUMS.txt'
$manifest = Get-Content -LiteralPath $manifestPath
if ($manifest.Count -lt 1) {
    throw 'The package SHA-256 manifest is empty.'
}
$manifestPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($line in $manifest) {
    if ($line -notmatch '^([A-F0-9]{64})  (.+)$') {
        throw "Malformed manifest line: $line"
    }
    $expectedHash = $Matches[1]
    $relative = $Matches[2]
    $segments = $relative.Split(
        [char[]]@('\', '/'),
        [StringSplitOptions]::None
    )
    if (
        [IO.Path]::IsPathRooted($relative) -or
        $segments.Count -eq 0 -or
        @($segments | Where-Object {
            [string]::IsNullOrWhiteSpace($_) -or
            $_ -in @('.', '..') -or
            $_.EndsWith('.') -or
            $_.EndsWith(' ') -or
            $_.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0
        }).Count -gt 0
    ) {
        throw "Unsafe manifest path: $relative"
    }
    if (-not $manifestPaths.Add($relative)) {
        throw "Duplicate manifest path: $relative"
    }
    $candidate = Join-Path $package $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Manifest file is missing: $relative"
    }
    $actualHash =
        (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch: $relative"
    }
}

$packagedFiles = $allPackageFiles |
    Where-Object Name -ne 'SHA256SUMS.txt'
if ($packagedFiles.Count -ne $manifestPaths.Count) {
    throw 'The SHA-256 manifest does not cover every packaged file.'
}
foreach ($file in $packagedFiles) {
    $relative = $file.FullName.Substring($package.Length + 1)
    if (-not $manifestPaths.Contains($relative)) {
        throw "Unlisted package file: $relative"
    }
}

$signableRelativePaths = @(
    'NvidiaAppOculinkUpdateBridge.exe',
    'payload\NvidiaAppOculinkShim.exe',
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.ps1',
    'MaintenanceManifest.ps1',
    'NvidiaAppOculinkShim.Common.psm1',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Setup.ps1',
    'Status.ps1',
    'Test-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.ps1'
)
$signedFiles = @(
    foreach ($relative in $signableRelativePaths) {
        Get-Item -LiteralPath (Join-Path $package $relative)
    }
)
$actualSignablePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($file in $allPackageFiles | Where-Object {
    $_.Extension -in @('.exe', '.ps1', '.psm1')
}) {
    $actualSignablePaths.Add(
        $file.FullName.Substring($package.Length + 1)
    ) | Out-Null
}
$expectedSignablePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($relative in $signableRelativePaths) {
    $expectedSignablePaths.Add($relative) | Out-Null
}
if (-not $actualSignablePaths.SetEquals($expectedSignablePaths)) {
    throw 'The package signable file set does not match its explicit allowlist.'
}
$signatureByPath = @{}
if ($ExpectInstallerBatchFiles) {
    foreach ($file in $signedFiles) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        $signatureByPath[$file.FullName] = $signature
        if (
            $signature.Status -ne 'NotSigned' -or
            $signature.SignerCertificate -or
            $signature.TimeStamperCertificate
        ) {
            throw (
                'The installer-batch preview must be consistently unsigned: ' +
                $file.Name
            )
        }
    }
}
if ($RequireTimestamp) {
    $RequireSignature = $true
}
if ($RequireSignature) {
    $serviceSignature = Get-AuthenticodeSignature -LiteralPath $serviceBinary
    $signatureByPath[$serviceBinary] = $serviceSignature
    if (-not $serviceSignature.SignerCertificate) {
        throw 'The packaged service executable has no signer certificate.'
    }
    $serviceSignerThumbprint =
        $serviceSignature.SignerCertificate.Thumbprint.ToUpperInvariant()
    $expectedSignerThumbprint = if ($useUntrustedTestRoot) {
        if ($serviceSignerThumbprint -ne $normalizedExpectedTestSigner) {
            throw 'The service signer does not match the expected test certificate.'
        }
        $normalizedExpectedTestSigner
    } else {
        $serviceSignerThumbprint
    }
    foreach ($file in $signedFiles) {
        $signature = $signatureByPath[$file.FullName]
        if (-not $signature) {
            $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
            $signatureByPath[$file.FullName] = $signature
        }
        if ($useUntrustedTestRoot) {
            & $testSignatureValidator `
                -Signature $signature `
                -ExpectedSignerThumbprint $expectedSignerThumbprint `
                -RootCertificatePath $resolvedTestRootCertificatePath `
                -FileName $file.Name
        } elseif (
            $signature.Status -ne 'Valid' -or
            -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -ne
                $expectedSignerThumbprint
        ) {
            throw "Required package signature is invalid for $($file.Name): $($signature.Status)"
        }
        if ($RequireTimestamp -and -not $signature.TimeStamperCertificate) {
            throw "Required package timestamp is missing for $($file.Name)"
        }
    }
}

$forbidden = @(
    'C:[\\/]Users[\\/](?!Public[\\/])',
    'Documents[\\/]Codex',
    '127\.0\.0\.1/[0-9A-Fa-f]{32,}/',
    '"token"\s*:\s*"[0-9A-Fa-f]{32,}"'
)
$textFiles = Get-ChildItem -LiteralPath $package -Recurse -File |
    Where-Object Extension -in @('.md', '.txt', '.json', '.ps1', '.psm1', '.cmd')
foreach ($file in $textFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $forbidden) {
        if ($content -match $pattern) {
            throw "Forbidden machine-specific content in $($file.FullName): $pattern"
        }
    }
}

$hashFile = $archive + '.sha256'
if (-not (Test-Path -LiteralPath $hashFile -PathType Leaf)) {
    throw 'The standalone archive SHA-256 file is missing.'
}
$hashLine = (Get-Content -LiteralPath $hashFile -Raw).Trim()
$archiveName = [IO.Path]::GetFileName($archive)
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($hashLine -ne "$archiveHash  $archiveName") {
    throw 'The standalone archive SHA-256 file does not match the ZIP.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$packageLeaf = Split-Path -Leaf $package
$entryPrefix = $packageLeaf + '/'
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $allPackagedFiles = @(Get-ChildItem -LiteralPath $package -Recurse -File)
    $diskPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($file in $allPackagedFiles) {
        $relative = $file.FullName.Substring($package.Length + 1)
        if (-not $diskPaths.Add($relative)) {
            throw "Duplicate package path after Windows normalization: $relative"
        }
    }
    $archivePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $archiveDirectories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in $zip.Entries) {
        $rawPath = $entry.FullName
        if (
            $rawPath.Contains('\') -or
            -not $rawPath.StartsWith(
            $entryPrefix,
            [StringComparison]::Ordinal
        )
        ) {
            throw "Unexpected ZIP entry root: $rawPath"
        }
        $relativePath = $rawPath.Substring($entryPrefix.Length)
        $isDirectory = $rawPath.EndsWith('/')
        if ([string]::IsNullOrEmpty($relativePath)) {
            if (-not $isDirectory) {
                throw "Invalid ZIP root entry: $rawPath"
            }
            continue
        }
        if ($isDirectory) {
            $relativePath = $relativePath.Substring(
                0,
                $relativePath.Length - 1
            )
        }
        $segments = $relativePath.Split(
            [char[]]'/',
            [StringSplitOptions]::None
        )
        if (@($segments | Where-Object {
            [string]::IsNullOrWhiteSpace($_) -or
            $_ -in @('.', '..') -or
            $_.EndsWith('.') -or
            $_.EndsWith(' ') -or
            $_.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0
        }).Count -gt 0) {
            throw "Unsafe ZIP entry: $rawPath"
        }
        $relative = $segments -join '\'
        $diskPath = [IO.Path]::GetFullPath((Join-Path $package $relative))
        $diskPrefix = $package.TrimEnd('\') + '\'
        if (-not $diskPath.StartsWith(
            $diskPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "ZIP entry escapes the package directory: $rawPath"
        }
        if ($isDirectory) {
            if (-not $archiveDirectories.Add($relative)) {
                throw "Duplicate ZIP directory entry: $relative"
            }
            if (-not (Test-Path -LiteralPath $diskPath -PathType Container)) {
                throw "ZIP directory has no package source directory: $relative"
            }
            continue
        }
        if ([string]::IsNullOrEmpty($entry.Name)) {
            throw "Malformed ZIP file entry: $rawPath"
        }
        if (-not $archivePaths.Add($relative)) {
            throw "Duplicate ZIP file entry: $relative"
        }

        if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
            throw "ZIP entry has no package source file: $relative"
        }
        $stream = $entry.Open()
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $entryHash = -join (
                $sha256.ComputeHash($stream) |
                    ForEach-Object { $_.ToString('X2') }
            )
        } finally {
            $sha256.Dispose()
            $stream.Dispose()
        }
        $diskHash =
            (Get-FileHash -LiteralPath $diskPath -Algorithm SHA256).Hash
        if ($entryHash -ne $diskHash) {
            throw "ZIP entry SHA-256 mismatch: $relative"
        }
    }
    if (-not $archivePaths.SetEquals($diskPaths)) {
        throw 'The ZIP file set does not exactly match the package directory.'
    }
} finally {
    $zip.Dispose()
}

foreach ($file in $signedFiles) {
    if (-not $signatureByPath[$file.FullName]) {
        $signatureByPath[$file.FullName] =
            Get-AuthenticodeSignature -LiteralPath $file.FullName
    }
}
$serviceSignature = $signatureByPath[$serviceBinary]
[pscustomobject]@{
    ManifestEntries = $manifest.Count
    MaintenanceManifestEntries = $maintenanceEntryCount
    ArchiveFileEntries = $archivePaths.Count
    ArchiveSha256 = $archiveHash
    Signature = $serviceSignature.Status
    SignerThumbprint =
        if ($serviceSignature.SignerCertificate) {
            $serviceSignature.SignerCertificate.Thumbprint
        } else {
            $null
        }
    SignedPowerShellFiles = @(
        $signedFiles |
            Where-Object Extension -in @('.ps1', '.psm1') |
            Where-Object {
                $useUntrustedTestRoot -or
                $signatureByPath[$_.FullName].Status -eq 'Valid'
            }
    ).Count
    SignedNativeExecutables = @(
        $signedFiles |
            Where-Object Extension -eq '.exe' |
            Where-Object {
                $useUntrustedTestRoot -or
                $signatureByPath[$_.FullName].Status -eq 'Valid'
            }
    ).Count
    PackageValid = $true
} | Format-List
