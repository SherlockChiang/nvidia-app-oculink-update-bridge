[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$testVersion = '4.0.0-signing-test'
$packageName = "NvidiaAppOculinkUpdateBridge-$testVersion-win-x64"
$packageRoot = Join-Path $artifactsRoot (Join-Path 'package' $packageName)
$archivePath = Join-Path $artifactsRoot ($packageName + '.zip')
$archiveHashPath = $archivePath + '.sha256'
$pfxPath = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('nvidia-oculink-signing-test-' + [Guid]::NewGuid() + '.pfx')
$passwordText = [Guid]::NewGuid().ToString('N')
$securePassword =
    ConvertTo-SecureString $passwordText -AsPlainText -Force
$certificate = $null
$publicCertificate = $null
$rsa = $null
$trustedStoreNames = @(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher
)

function Remove-TestArtifact {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return
    }
    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    $artifactsPrefix =
        [IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith(
        $artifactsPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to remove an unexpected test artifact: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

try {
    New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
    & (Join-Path $repositoryRoot 'build\Publish-Package.ps1') `
        -Version $testVersion `
        -SkipBuild

    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $subject = 'CN=NVIDIA App OCuLink signing pipeline test ' + [Guid]::NewGuid()
    $request =
        [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            $subject,
            $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $false,
            $false,
            0,
            $true
        )
    )
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,
            $true
        )
    )
    $enhancedKeyUsages =
        [Security.Cryptography.OidCollection]::new()
    $enhancedKeyUsages.Add(
        [Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3')
    ) | Out-Null
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
            $enhancedKeyUsages,
            $true
        )
    )
    $certificate = $request.CreateSelfSigned(
        [DateTimeOffset]::UtcNow.AddMinutes(-5),
        [DateTimeOffset]::UtcNow.AddDays(2)
    )
    [IO.File]::WriteAllBytes(
        $pfxPath,
        $certificate.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
            $passwordText
        )
    )
    $publicCertificate =
        [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $certificate.Export(
                [Security.Cryptography.X509Certificates.X509ContentType]::Cert
            )
        )

    foreach ($storeName in $trustedStoreNames) {
        $store =
            [Security.Cryptography.X509Certificates.X509Store]::new(
                $storeName,
                [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
            )
        try {
            $store.Open(
                [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite
            )
            $store.Add($publicCertificate)
        } finally {
            $store.Dispose()
        }
    }

    $thumbprintMismatchRejected = $false
    try {
        & (Join-Path $repositoryRoot 'build\Sign-Package.ps1') `
            -PackagePath $packageRoot `
            -SigningCertificatePath $pfxPath `
            -SigningCertificatePassword $securePassword `
            -ExpectedSignerThumbprint ('0' * 40) `
            -TimestampServer ''
    } catch {
        if ($_.Exception.Message -notmatch 'does not match') {
            throw
        }
        $thumbprintMismatchRejected = $true
    }
    if (-not $thumbprintMismatchRejected) {
        throw 'The signing pipeline accepted an unexpected certificate thumbprint.'
    }

    & (Join-Path $repositoryRoot 'build\Sign-Package.ps1') `
        -PackagePath $packageRoot `
        -SigningCertificatePath $pfxPath `
        -SigningCertificatePassword $securePassword `
        -ExpectedSignerThumbprint $certificate.Thumbprint `
        -TimestampServer ''
    & (Join-Path $repositoryRoot 'build\Finalize-Package.ps1') `
        -PackagePath $packageRoot `
        -ArchivePath $archivePath `
        -RequireSignature
    & (Join-Path $PSScriptRoot 'Test-Package.ps1') `
        -PackagePath $packageRoot `
        -ArchivePath $archivePath `
        -RequireSignature

    Write-Output 'Signing pipeline self-test passed.'
} finally {
    if ($publicCertificate) {
        foreach ($storeName in $trustedStoreNames) {
            $store =
                [Security.Cryptography.X509Certificates.X509Store]::new(
                    $storeName,
                    [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
                )
            try {
                $store.Open(
                    [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite
                )
                $matches = $store.Certificates.Find(
                    [Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                    $publicCertificate.Thumbprint,
                    $false
                )
                foreach ($match in $matches) {
                    $store.Remove($match)
                }
            } finally {
                $store.Dispose()
            }
        }
    }
    Remove-TestArtifact -LiteralPath $packageRoot
    Remove-TestArtifact -LiteralPath $archivePath
    Remove-TestArtifact -LiteralPath $archiveHashPath
    if (Test-Path -LiteralPath $pfxPath) {
        $resolvedPfx = [IO.Path]::GetFullPath($pfxPath)
        $temporaryPrefix = [IO.Path]::GetFullPath(
            [IO.Path]::GetTempPath()
        ).TrimEnd('\') + '\'
        if (-not $resolvedPfx.StartsWith(
            $temporaryPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to remove an unexpected test PFX: $resolvedPfx"
        }
        Remove-Item -LiteralPath $resolvedPfx -Force
    }
    if ($publicCertificate) { $publicCertificate.Dispose() }
    if ($certificate) { $certificate.Dispose() }
    if ($rsa) { $rsa.Dispose() }
}
