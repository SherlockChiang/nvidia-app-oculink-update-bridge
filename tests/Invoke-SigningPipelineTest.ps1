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
$issuerCerPath = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('nvidia-oculink-signing-test-root-' + [Guid]::NewGuid() + '.cer')
$passwordText = [Guid]::NewGuid().ToString('N')
$securePassword =
    ConvertTo-SecureString $passwordText -AsPlainText -Force
$certificate = $null
$issuerCertificate = $null
$issuerPublicCertificate = $null
$rsa = $null
$issuerRsa = $null

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
        -Version $testVersion

    Write-Output 'Creating an isolated test CA and code-signing certificate ...'
    $issuerRsa = [Security.Cryptography.RSA]::Create(2048)
    $issuerRequest =
        [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            ('CN=NVIDIA App OCuLink signing test CA ' + [Guid]::NewGuid()),
            $issuerRsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    $issuerRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $true,
            $false,
            0,
            $true
        )
    )
    $issuerRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            (
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign
            ),
            $true
        )
    )
    $issuerRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new(
            $issuerRequest.PublicKey,
            $false
        )
    )
    $notBefore = [DateTimeOffset]::UtcNow.AddMinutes(-5)
    $notAfter = [DateTimeOffset]::UtcNow.AddDays(2)
    $issuerCertificate = $issuerRequest.CreateSelfSigned($notBefore, $notAfter)

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
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new(
            $request.PublicKey,
            $false
        )
    )
    $issuedCertificate = $request.Create(
        $issuerCertificate,
        $notBefore,
        $notAfter.AddMinutes(-1),
        [Guid]::NewGuid().ToByteArray()
    )
    try {
        $certificate =
            [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey(
                $issuedCertificate,
                $rsa
            )
    } finally {
        $issuedCertificate.Dispose()
    }
    $issuerPublicCertificate =
        [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $issuerCertificate.Export(
                [Security.Cryptography.X509Certificates.X509ContentType]::Cert
            )
        )
    $pfxCertificates =
        [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $pfxCertificates.Add($certificate) | Out-Null
    $pfxCertificates.Add($issuerPublicCertificate) | Out-Null
    [IO.File]::WriteAllBytes(
        $pfxPath,
        $pfxCertificates.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
            $passwordText
        )
    )
    [IO.File]::WriteAllBytes(
        $issuerCerPath,
        $issuerPublicCertificate.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Cert
        )
    )
    $issuerStore =
        [Security.Cryptography.X509Certificates.X509Store]::new(
            [Security.Cryptography.X509Certificates.StoreName]::CertificateAuthority,
            [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
        )
    try {
        $issuerStore.Open(
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite
        )
        $issuerStore.Add($issuerPublicCertificate)
    } finally {
        $issuerStore.Dispose()
    }
    Write-Output (
        'Temporary issuer added only to CurrentUser\CA for chain building; ' +
        'no root trust was granted.'
    )

    $thumbprintMismatchRejected = $false
    try {
        & (Join-Path $repositoryRoot 'build\Sign-Package.ps1') `
            -PackagePath $packageRoot `
            -SigningCertificatePath $pfxPath `
            -SigningCertificatePassword $securePassword `
            -ExpectedSignerThumbprint ('0' * 40) `
            -UntrustedTestRootCertificatePath $issuerCerPath `
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
        -UntrustedTestRootCertificatePath $issuerCerPath `
        -TimestampServer ''

    $runtimeTrustStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $runtimeTrustStartInfo.FileName =
        Join-Path $packageRoot 'NvidiaAppOculinkUpdateBridge.exe'
    $runtimeTrustStartInfo.Arguments = '--verify-package'
    $runtimeTrustStartInfo.WorkingDirectory = $packageRoot
    $runtimeTrustStartInfo.UseShellExecute = $false
    $runtimeTrustStartInfo.CreateNoWindow = $true
    $runtimeTrustStartInfo.RedirectStandardOutput = $true
    $runtimeTrustStartInfo.RedirectStandardError = $true
    $runtimeTrustProcess = [Diagnostics.Process]::new()
    $runtimeTrustProcess.StartInfo = $runtimeTrustStartInfo
    try {
        if (-not $runtimeTrustProcess.Start()) {
            throw 'The launcher runtime trust process did not start.'
        }
        $runtimeTrustOutputTask =
            $runtimeTrustProcess.StandardOutput.ReadToEndAsync()
        $runtimeTrustErrorTask =
            $runtimeTrustProcess.StandardError.ReadToEndAsync()
        if (-not $runtimeTrustProcess.WaitForExit(30000)) {
            Stop-Process `
                -Id $runtimeTrustProcess.Id `
                -Force `
                -ErrorAction SilentlyContinue
            $runtimeTrustProcess.WaitForExit()
            throw 'The launcher runtime trust rejection timed out.'
        }
        [Threading.Tasks.Task]::WaitAll(@(
            $runtimeTrustOutputTask,
            $runtimeTrustErrorTask
        ))
        $runtimeTrustExitCode = $runtimeTrustProcess.ExitCode
        $runtimeTrustOutput = $runtimeTrustOutputTask.Result
        $runtimeTrustError = $runtimeTrustErrorTask.Result
    } finally {
        $runtimeTrustProcess.Dispose()
    }
    if ($runtimeTrustExitCode -eq 0) {
        throw 'The launcher runtime accepted the untrusted test certificate.'
    }
    if ($runtimeTrustError -notmatch 'WinVerifyTrust=0x800B0109') {
        throw (
            'The launcher failed for an unexpected reason instead of ' +
            'CERT_E_UNTRUSTEDROOT (0x800B0109). stdout=' +
            $runtimeTrustOutput.Trim() + '; stderr=' +
            $runtimeTrustError.Trim()
        )
    }
    Write-Output 'Launcher runtime trust gate rejected the untrusted test root.'

    $strictTrustRejected = $false
    try {
        & (Join-Path $repositoryRoot 'build\Finalize-Package.ps1') `
            -PackagePath $packageRoot `
            -ArchivePath $archivePath `
            -RequireSignature
    } catch {
        if ($_.Exception.Message -notmatch 'signatures are invalid') {
            throw
        }
        $strictTrustRejected = $true
    }
    if (-not $strictTrustRejected) {
        throw 'The strict release gate accepted an untrusted test root.'
    }
    Write-Output 'Strict release trust gate rejected the untrusted test root.'

    foreach ($tamperRelativePath in @(
        'Setup.ps1',
        'NvidiaAppOculinkUpdateBridge.exe',
        'MaintenanceManifest.ps1'
    )) {
        $tamperTarget = Join-Path $packageRoot $tamperRelativePath
        $originalBytes = [IO.File]::ReadAllBytes($tamperTarget)
        $tamperedBytes = [byte[]]$originalBytes.Clone()
        $tamperOffset = if (
            [IO.Path]::GetExtension($tamperRelativePath) -eq '.exe'
        ) {
            [Math]::Min(4096, $tamperedBytes.Length - 1)
        } else {
            0
        }
        $tamperedBytes[$tamperOffset] =
            $tamperedBytes[$tamperOffset] -bxor 1
        $tamperRejected = $false
        try {
            [IO.File]::WriteAllBytes($tamperTarget, $tamperedBytes)
            try {
                & (Join-Path $repositoryRoot 'build\Finalize-Package.ps1') `
                    -PackagePath $packageRoot `
                    -ArchivePath $archivePath `
                    -RequireSignature `
                    -UntrustedTestRootCertificatePath $issuerCerPath `
                    -ExpectedTestSignerThumbprint $certificate.Thumbprint
            } catch {
                if ($_.Exception.Message -notmatch 'HashMismatch') {
                    throw
                }
                $tamperRejected = $true
            }
        } finally {
            [IO.File]::WriteAllBytes($tamperTarget, $originalBytes)
        }
        if (-not $tamperRejected) {
            throw (
                'The signature gate accepted a tampered signed file: ' +
                $tamperRelativePath
            )
        }
        Write-Output (
            'Authenticode gate rejected tampering of ' + $tamperRelativePath + '.'
        )
    }

    & (Join-Path $repositoryRoot 'build\Finalize-Package.ps1') `
        -PackagePath $packageRoot `
        -ArchivePath $archivePath `
        -RequireSignature `
        -UntrustedTestRootCertificatePath $issuerCerPath `
        -ExpectedTestSignerThumbprint $certificate.Thumbprint
    & (Join-Path $PSScriptRoot 'Test-Package.ps1') `
        -PackagePath $packageRoot `
        -ArchivePath $archivePath `
        -RequireSignature `
        -UntrustedTestRootCertificatePath $issuerCerPath `
        -ExpectedTestSignerThumbprint $certificate.Thumbprint

    Write-Output 'Signing pipeline self-test passed.'
} finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    if ($issuerPublicCertificate) {
        $issuerStore =
            [Security.Cryptography.X509Certificates.X509Store]::new(
                [Security.Cryptography.X509Certificates.StoreName]::CertificateAuthority,
                [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
            )
        try {
            $issuerStore.Open(
                [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite
            )
            $matches = $issuerStore.Certificates.Find(
                [Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                $issuerPublicCertificate.Thumbprint,
                $false
            )
            foreach ($match in $matches) {
                $issuerStore.Remove($match)
            }
            $remaining = $issuerStore.Certificates.Find(
                [Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                $issuerPublicCertificate.Thumbprint,
                $false
            )
            if ($remaining.Count -ne 0) {
                throw 'The temporary issuer is still present after removal.'
            }
            Write-Output 'Temporary CurrentUser\CA issuer removed.'
        } catch {
            $cleanupFailures.Add(
                (
                    "issuer $($issuerPublicCertificate.Thumbprint) removal: " +
                    $_.Exception.Message
                )
            )
        } finally {
            $issuerStore.Dispose()
        }
    }
    foreach ($artifactPath in @(
        $packageRoot,
        $archivePath,
        $archiveHashPath
    )) {
        try {
            Remove-TestArtifact -LiteralPath $artifactPath
        } catch {
            $cleanupFailures.Add(
                "artifact removal ($artifactPath): $($_.Exception.Message)"
            )
        }
    }
    foreach ($temporaryPath in @($pfxPath, $issuerCerPath)) {
        try {
            if (-not (Test-Path -LiteralPath $temporaryPath)) {
                continue
            }
            $resolvedTemporaryPath = [IO.Path]::GetFullPath($temporaryPath)
            $temporaryPrefix = [IO.Path]::GetFullPath(
                [IO.Path]::GetTempPath()
            ).TrimEnd('\') + '\'
            if (-not $resolvedTemporaryPath.StartsWith(
                $temporaryPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "Refusing to remove an unexpected temporary file: $resolvedTemporaryPath"
            }
            Remove-Item -LiteralPath $resolvedTemporaryPath -Force
        } catch {
            $cleanupFailures.Add(
                "temporary file removal ($temporaryPath): $($_.Exception.Message)"
            )
        }
    }
    if ($certificate) { $certificate.Dispose() }
    if ($issuerPublicCertificate) { $issuerPublicCertificate.Dispose() }
    if ($issuerCertificate) { $issuerCertificate.Dispose() }
    if ($rsa) { $rsa.Dispose() }
    if ($issuerRsa) { $issuerRsa.Dispose() }
    if ($cleanupFailures.Count -gt 0) {
        throw "Signing test cleanup failed: $($cleanupFailures -join '; ')"
    }
}
