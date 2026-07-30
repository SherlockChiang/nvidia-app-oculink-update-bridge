[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,
    [Parameter(Mandatory)]
    [string]$SigningCertificatePath,
    [Parameter(Mandatory)]
    [Security.SecureString]$SigningCertificatePassword,
    [AllowEmptyString()]
    [string]$TimestampServer = 'http://timestamp.digicert.com'
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

$certificatePath =
    (Resolve-Path -LiteralPath $SigningCertificatePath).Path
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($certificatePath.StartsWith(
    $repositoryPrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The signing certificate must not be stored inside the repository.'
}

if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
    $timestampUri = $null
    if (
        -not [Uri]::TryCreate(
            $TimestampServer,
            [UriKind]::Absolute,
            [ref]$timestampUri
        ) -or
        $timestampUri.Host -ne 'timestamp.digicert.com' -or
        $timestampUri.Scheme -notin @('http', 'https')
    ) {
        throw 'TimestampServer must be http(s)://timestamp.digicert.com.'
    }
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
        $item = Get-Item -LiteralPath $candidate
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to sign a reparse point: $relative"
        }
        $item
    }
)

$certificateFlags =
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
$certificate =
    [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certificatePath,
        $SigningCertificatePassword,
        $certificateFlags
    )
try {
    if (-not $certificate.HasPrivateKey) {
        throw 'The signing certificate does not contain a private key.'
    }
    $expectedSignerThumbprint = $certificate.Thumbprint
    foreach ($file in $signableFiles) {
        $signatureParameters = @{
            LiteralPath = $file.FullName
            Certificate = $certificate
            HashAlgorithm = 'SHA256'
        }
        if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
            $signatureParameters.TimestampServer = $TimestampServer
        }
        $signature = Set-AuthenticodeSignature @signatureParameters
        if (
            $signature.Status -ne 'Valid' -or
            -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -ne
                $expectedSignerThumbprint
        ) {
            throw "Signing failed for $($file.Name): $($signature.Status)"
        }
        if (
            -not [string]::IsNullOrWhiteSpace($TimestampServer) -and
            -not $signature.TimeStamperCertificate
        ) {
            throw "The signature was not timestamped: $($file.Name)"
        }
    }
} finally {
    $certificate.Dispose()
}

foreach ($file in $signableFiles) {
    $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
    if (
        $signature.Status -ne 'Valid' -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $expectedSignerThumbprint
    ) {
        throw "Signature validation failed for $($file.Name): $($signature.Status)"
    }
    if (
        -not [string]::IsNullOrWhiteSpace($TimestampServer) -and
        -not $signature.TimeStamperCertificate
    ) {
        throw "Timestamp validation failed for $($file.Name)"
    }
}

[pscustomobject]@{
    Package = $package
    SignedFiles = $signableFiles.Count
    SignatureStatus = 'Valid'
    SignerThumbprint = $expectedSignerThumbprint
    Timestamped = -not [string]::IsNullOrWhiteSpace($TimestampServer)
} | Format-List
