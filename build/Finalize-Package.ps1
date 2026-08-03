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
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$packageParent = Join-Path $artifactsRoot 'package'
$package = (Resolve-Path -LiteralPath $PackagePath).Path
$packagePrefix = [IO.Path]::GetFullPath($packageParent).TrimEnd('\') + '\'
if (-not $package.StartsWith(
    $packagePrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Package must be below the repository artifacts directory: $package"
}

$packageLeaf = Split-Path -Leaf $package
$expectedArchive =
    [IO.Path]::GetFullPath((Join-Path $artifactsRoot ($packageLeaf + '.zip')))
$archive = [IO.Path]::GetFullPath($ArchivePath)
if (-not $archive.Equals(
    $expectedArchive,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Unexpected archive path: $archive"
}
$archiveHashPath = $archive + '.sha256'

$reparsePoints = @(
    Get-ChildItem -LiteralPath $package -Recurse -Force |
        Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }
)
if ($reparsePoints.Count -gt 0) {
    throw "The package contains a reparse point: $($reparsePoints[0].FullName)"
}

$signableRelativePaths = @(
    'payload\NvidiaAppOculinkShim.exe',
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.ps1',
    'NvidiaAppOculinkShim.Common.psm1',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Setup.ps1',
    'Status.ps1',
    'Test-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.ps1'
)
$signableFiles = @(
    foreach ($relative in $signableRelativePaths) {
        $candidate = Join-Path $package $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Required signable file is missing: $relative"
        }
        Get-Item -LiteralPath $candidate
    }
)
$signatureByPath = @{}
if ($RequireTimestamp) {
    $RequireSignature = $true
}
if ($RequireSignature) {
    $serviceSignature =
        Get-AuthenticodeSignature -LiteralPath $signableFiles[0].FullName
    $signatureByPath[$signableFiles[0].FullName] = $serviceSignature
    if (-not $serviceSignature.SignerCertificate) {
        throw 'The service executable has no Authenticode signer certificate.'
    }
    $expectedSignerThumbprint =
        $serviceSignature.SignerCertificate.Thumbprint
    $signatureFailures = @(
        foreach ($file in $signableFiles) {
            $signature = $signatureByPath[$file.FullName]
            if (-not $signature) {
                $signature =
                    Get-AuthenticodeSignature -LiteralPath $file.FullName
                $signatureByPath[$file.FullName] = $signature
            }
            if (
                $signature.Status -ne 'Valid' -or
                -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Thumbprint -ne
                    $expectedSignerThumbprint
            ) {
                "$($file.Name): $($signature.Status)"
            } elseif (
                $RequireTimestamp -and
                -not $signature.TimeStamperCertificate
            ) {
                "$($file.Name): missing timestamp"
            }
        }
    )
    if ($signatureFailures.Count -gt 0) {
        throw (
            'Required Authenticode signatures are invalid: ' +
            ($signatureFailures -join ', ')
        )
    }
}

$manifestPath = Join-Path $package 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $manifestPath) {
    Remove-Item -LiteralPath $manifestPath -Force
}
$manifest = Get-ChildItem -LiteralPath $package -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($package.Length + 1)
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        "$hash  $relative"
    }
[IO.File]::WriteAllLines(
    $manifestPath,
    $manifest,
    [Text.UTF8Encoding]::new($false)
)

if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
if (Test-Path -LiteralPath $archiveHashPath) {
    Remove-Item -LiteralPath $archiveHashPath -Force
}
Compress-Archive `
    -LiteralPath $package `
    -DestinationPath $archive `
    -CompressionLevel Optimal
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
[IO.File]::WriteAllText(
    $archiveHashPath,
    "$archiveHash  $([IO.Path]::GetFileName($archive))`n",
    [Text.UTF8Encoding]::new($false)
)

foreach ($file in $signableFiles) {
    if (-not $signatureByPath[$file.FullName]) {
        $signatureByPath[$file.FullName] =
            Get-AuthenticodeSignature -LiteralPath $file.FullName
    }
}
$serviceSignature = $signatureByPath[$signableFiles[0].FullName]
[pscustomobject]@{
    Package = $package
    Archive = $archive
    ArchiveSha256 = $archiveHash
    ArchiveHashFile = $archiveHashPath
    ServiceSignature = $serviceSignature.Status
    SignerThumbprint =
        if ($serviceSignature.SignerCertificate) {
            $serviceSignature.SignerCertificate.Thumbprint
        } else {
            $null
        }
    SignedPowerShellFiles = @(
        $signableFiles |
            Where-Object Extension -in @('.ps1', '.psm1') |
            Where-Object {
                $signatureByPath[$_.FullName].Status -eq 'Valid'
            }
    ).Count
} | Format-List
