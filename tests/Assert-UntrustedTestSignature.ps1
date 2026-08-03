[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [System.Management.Automation.Signature]$Signature,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedSignerThumbprint,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RootCertificatePath,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FileName
)

$ErrorActionPreference = 'Stop'
$codeSigningOid = '1.3.6.1.5.5.7.3.3'
$certEUntrustedRoot = [Convert]::ToUInt32('800B0109', 16)

function Stop-SignatureValidation {
    param([Parameter(Mandatory)][string]$Message)

    throw "${FileName}: $Message"
}

if ($ExpectedSignerThumbprint -notmatch '\A[0-9A-Fa-f]{40}\z') {
    Stop-SignatureValidation `
        'the expected signer thumbprint must be exactly 40 hexadecimal characters.'
}
if (-not $Signature.SignerCertificate) {
    Stop-SignatureValidation 'the signature has no signer certificate.'
}
$actualSignerThumbprint = $Signature.SignerCertificate.Thumbprint
if (
    -not [string]::Equals(
        $actualSignerThumbprint,
        $ExpectedSignerThumbprint,
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    Stop-SignatureValidation (
        'the signer thumbprint does not match the expected thumbprint ' +
        "($actualSignerThumbprint != $ExpectedSignerThumbprint)."
    )
}

$allowedStatuses = @(
    [System.Management.Automation.SignatureStatus]::UnknownError,
    [System.Management.Automation.SignatureStatus]::NotTrusted
)
if ($Signature.Status -notin $allowedStatuses) {
    Stop-SignatureValidation (
        "the Authenticode status is $($Signature.Status); expected " +
        'UnknownError or NotTrusted for an isolated test root.'
    )
}

$errorFields = [Collections.Generic.List[Reflection.FieldInfo]]::new()
$signatureType = $Signature.GetType()
$fieldFlags =
    [Reflection.BindingFlags]::Instance -bor
    [Reflection.BindingFlags]::NonPublic -bor
    [Reflection.BindingFlags]::DeclaredOnly
while ($signatureType) {
    foreach ($fieldName in @('win32Error', '_win32Error')) {
        $field = $signatureType.GetField($fieldName, $fieldFlags)
        if ($field) {
            $errorFields.Add($field)
        }
    }
    $signatureType = $signatureType.BaseType
}
if ($errorFields.Count -eq 0) {
    Stop-SignatureValidation (
        'the private win32Error/_win32Error field is unavailable; ' +
        'refusing to infer trust failure from the public status alone.'
    )
}

foreach ($field in $errorFields) {
    $fieldValue = $field.GetValue($Signature)
    if ($fieldValue -is [uint32]) {
        $rawWin32Error = [uint32]$fieldValue
    } elseif ($fieldValue -is [int32]) {
        $rawWin32Error = [BitConverter]::ToUInt32(
            [BitConverter]::GetBytes([int32]$fieldValue),
            0
        )
    } else {
        $valueType =
            if ($null -eq $fieldValue) {
                '<null>'
            } else {
                $fieldValue.GetType().FullName
            }
        Stop-SignatureValidation (
            "the private $($field.Name) field has unsupported type $valueType; " +
            'only raw Int32 and UInt32 HRESULT fields are accepted.'
        )
    }
    if ($rawWin32Error -ne $certEUntrustedRoot) {
        Stop-SignatureValidation (
            ('the private {0} HRESULT is 0x{1:X8}; expected ' -f
                $field.Name, $rawWin32Error) +
            'CERT_E_UNTRUSTEDROOT (0x800B0109).'
        )
    }
}

if (-not (Test-Path -LiteralPath $RootCertificatePath -PathType Leaf)) {
    Stop-SignatureValidation (
        "the test root certificate does not exist: $RootCertificatePath"
    )
}
$resolvedRootCertificatePath =
    (Resolve-Path -LiteralPath $RootCertificatePath).ProviderPath
$rootCertificate = $null
$chain = $null
try {
    $rootCertificate =
        [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $resolvedRootCertificatePath
        )
    $rootThumbprint = $rootCertificate.Thumbprint
    if ($rootThumbprint -notmatch '\A[0-9A-Fa-f]{40}\z') {
        Stop-SignatureValidation (
            'the test root certificate has no usable SHA-1 thumbprint.'
        )
    }

    $chain =
        [Security.Cryptography.X509Certificates.X509Chain]::new()
    $chain.ChainPolicy.TrustMode =
        [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
    $chain.ChainPolicy.CustomTrustStore.Add($rootCertificate) | Out-Null
    $chain.ChainPolicy.RevocationMode =
        [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $chain.ChainPolicy.VerificationFlags =
        [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
    $chain.ChainPolicy.DisableCertificateDownloads = $true
    $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::Zero
    $chain.ChainPolicy.ApplicationPolicy.Add(
        [Security.Cryptography.Oid]::new($codeSigningOid)
    ) | Out-Null

    if (-not $chain.Build($Signature.SignerCertificate)) {
        $chainErrors = @(
            $chain.ChainStatus |
                Where-Object Status -ne 'NoError' |
                ForEach-Object { $_.Status.ToString() }
        )
        $errorSummary =
            if ($chainErrors.Count -gt 0) {
                $chainErrors -join ', '
            } else {
                '<no chain status was reported>'
            }
        Stop-SignatureValidation (
            "the isolated code-signing chain did not build: $errorSummary"
        )
    }
    if ($chain.ChainElements.Count -ne 2) {
        Stop-SignatureValidation (
            'the isolated code-signing chain must contain exactly the leaf ' +
            "and test root; found $($chain.ChainElements.Count) elements."
        )
    }

    $chainLeafThumbprint =
        $chain.ChainElements[0].Certificate.Thumbprint
    $chainRootThumbprint =
        $chain.ChainElements[1].Certificate.Thumbprint
    if (
        -not [string]::Equals(
            $chainLeafThumbprint,
            $ExpectedSignerThumbprint,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Stop-SignatureValidation (
            'the first chain element does not match the expected signer ' +
            "thumbprint ($chainLeafThumbprint != $ExpectedSignerThumbprint)."
        )
    }
    if (
        -not [string]::Equals(
            $chainRootThumbprint,
            $rootThumbprint,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Stop-SignatureValidation (
            'the last chain element does not match the supplied test root ' +
            "thumbprint ($chainRootThumbprint != $rootThumbprint)."
        )
    }
} finally {
    if ($chain) {
        $chain.Dispose()
    }
    if ($rootCertificate) {
        $rootCertificate.Dispose()
    }
}
