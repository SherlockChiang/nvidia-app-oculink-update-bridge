[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,
    [Parameter(Mandatory)]
    [string]$ArchivePath,
    [switch]$RequireSignature,
    [switch]$RequireTimestamp
)

$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackagePath).Path
$archive = (Resolve-Path -LiteralPath $ArchivePath).Path
$reparsePoints = @(
    Get-ChildItem -LiteralPath $package -Recurse -Force |
        Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }
)
if ($reparsePoints.Count -gt 0) {
    throw "The package contains a reparse point: $($reparsePoints[0].FullName)"
}
$requiredFiles = @(
    'Install-NvidiaAppOculinkShim.cmd',
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.cmd',
    'Migrate-V3ToV4.ps1',
    'NvidiaAppOculinkShim.Common.psm1',
    'Repair-NvidiaAppOculinkShim.cmd',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Setup.cmd',
    'Setup.ps1',
    'Status.cmd',
    'Status.ps1',
    'Test-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.cmd',
    'Uninstall-NvidiaAppOculinkShim.ps1',
    'payload\NvidiaAppOculinkShim.exe',
    'README.md',
    'README.zh-CN.md',
    'LICENSE',
    'SECURITY.md',
    'CHANGELOG.md',
    'docs\github-release.zh-CN.md',
    'docs\product-architecture.zh-CN.md',
    'docs\release-status.zh-CN.md',
    'docs\workflow.zh-CN.md',
    'BUILD-INFO.txt',
    'SHA256SUMS.txt'
)
foreach ($relative in $requiredFiles) {
    $candidate = Join-Path $package $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Package file is missing: $relative"
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

$serviceBinary = Join-Path $package 'payload\NvidiaAppOculinkShim.exe'
$signedFiles = @(
    Get-Item -LiteralPath $serviceBinary
    Get-ChildItem -LiteralPath $package -Recurse -File |
        Where-Object Extension -in @('.ps1', '.psm1')
)
$signatureByPath = @{}
if ($RequireTimestamp) {
    $RequireSignature = $true
}
if ($RequireSignature) {
    $serviceSignature = Get-AuthenticodeSignature -LiteralPath $serviceBinary
    $signatureByPath[$signedFiles[0].FullName] = $serviceSignature
    if (-not $serviceSignature.SignerCertificate) {
        throw 'The packaged service executable has no signer certificate.'
    }
    $expectedSignerThumbprint =
        $serviceSignature.SignerCertificate.Thumbprint
    foreach ($file in $signedFiles) {
        $signature = $signatureByPath[$file.FullName]
        if (-not $signature) {
            $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
            $signatureByPath[$file.FullName] = $signature
        }
        if (
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
$serviceSignature = $signatureByPath[$signedFiles[0].FullName]
[pscustomobject]@{
    ManifestEntries = $manifest.Count
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
                $signatureByPath[$_.FullName].Status -eq 'Valid'
            }
    ).Count
    PackageValid = $true
} | Format-List
