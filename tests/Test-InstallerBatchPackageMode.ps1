[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,
    [Parameter(Mandatory)]
    [string]$ArchivePath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$packageRoot = (Resolve-Path -LiteralPath $PackagePath).Path
$archive = (Resolve-Path -LiteralPath $ArchivePath).Path
$packagePrefix =
    [IO.Path]::GetFullPath((Join-Path $artifactsRoot 'package')).TrimEnd('\') +
    '\'
if (-not $packageRoot.StartsWith(
    $packagePrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The test package must be below artifacts\package.'
}
$archivePrefix = [IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\') + '\'
if (-not $archive.StartsWith(
    $archivePrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The test archive must be below artifacts.'
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,
        [Parameter(Mandatory)]
        [string]$ExpectedMessage,
        [Parameter(Mandatory)]
        [string]$Description
    )

    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -like $ExpectedMessage) {
            Write-Output "$Description was rejected."
            return
        }
        throw (
            "$Description failed with an unexpected error: " +
            $_.Exception.Message
        )
    }
    throw "$Description was unexpectedly accepted."
}

$testPackageScript = Join-Path $PSScriptRoot 'Test-Package.ps1'
$finalizeScript = Join-Path $repositoryRoot 'build\Finalize-Package.ps1'
$signScript = Join-Path $repositoryRoot 'build\Sign-Package.ps1'
$dummyPassword = ConvertTo-SecureString 'not-used' -AsPlainText -Force
$dummyCertificate = Join-Path $artifactsRoot 'missing-preview-test.pfx'
$dummyThumbprint = '0000000000000000000000000000000000000000'

Assert-Rejected `
    -Description 'Undeclared installer-batch preview' `
    -ExpectedMessage 'The package file set does not match the explicit allowlist.' `
    -Action {
        & $testPackageScript `
            -PackagePath $packageRoot `
            -ArchivePath $archive
    }
Assert-Rejected `
    -Description 'Signature-required installer-batch preview validation' `
    -ExpectedMessage 'Installer batch entry points are forbidden in a signed package.*' `
    -Action {
        & $testPackageScript `
            -PackagePath $packageRoot `
            -ArchivePath $archive `
            -ExpectInstallerBatchFiles `
            -RequireSignature
    }
Assert-Rejected `
    -Description 'Unsigned preview finalized without its explicit mode' `
    -ExpectedMessage 'BUILD-INFO does not match the installer-batch package mode.' `
    -Action {
        & $finalizeScript `
            -PackagePath $packageRoot `
            -ArchivePath $archive
    }
Assert-Rejected `
    -Description 'Signed finalization of an installer-batch preview' `
    -ExpectedMessage 'Installer batch entry points are forbidden in a signed package.*' `
    -Action {
        & $finalizeScript `
            -PackagePath $packageRoot `
            -ArchivePath $archive `
            -IncludeInstallerBatchFiles `
            -RequireSignature
    }
Assert-Rejected `
    -Description 'Signing a marked installer-batch preview' `
    -ExpectedMessage 'Refusing to sign an installer-batch preview package.' `
    -Action {
        & $signScript `
            -PackagePath $packageRoot `
            -SigningCertificatePath $dummyCertificate `
            -SigningCertificatePassword $dummyPassword `
            -ExpectedSignerThumbprint $dummyThumbprint `
            -TimestampServer ''
    }

$negativeId = [Guid]::NewGuid().ToString('N')
$negativePackage = Join-Path `
    (Join-Path $artifactsRoot 'package') `
    "installer-batch-negative-$negativeId"
$negativeArchive = Join-Path `
    $artifactsRoot `
    "installer-batch-negative-$negativeId.zip"
try {
    Copy-Item `
        -LiteralPath $packageRoot `
        -Destination $negativePackage `
        -Recurse
    Copy-Item -LiteralPath $archive -Destination $negativeArchive

    $rogueDocumentation = Join-Path $negativePackage 'README.md'
    [IO.File]::WriteAllText(
        $rogueDocumentation,
        "Repository documentation must not be shipped.`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Rejected `
        -Description 'Preview containing repository documentation' `
        -ExpectedMessage 'The package file set does not match the explicit allowlist.' `
        -Action {
            & $testPackageScript `
                -PackagePath $negativePackage `
                -ArchivePath $negativeArchive `
                -ExpectInstallerBatchFiles
        }
    Remove-Item -LiteralPath $rogueDocumentation -Force

    $rogueBatch = Join-Path $negativePackage 'installer\Unexpected.cmd'
    [IO.File]::WriteAllText(
        $rogueBatch,
        "@echo off`r`nexit /b 0`r`n",
        [Text.ASCIIEncoding]::new()
    )
    Assert-Rejected `
        -Description 'Preview containing a rogue batch file' `
        -ExpectedMessage 'The package file set does not match the explicit allowlist.' `
        -Action {
            & $testPackageScript `
                -PackagePath $negativePackage `
                -ArchivePath $negativeArchive `
                -ExpectInstallerBatchFiles
        }
    Remove-Item -LiteralPath $rogueBatch -Force

    Remove-Item `
        -LiteralPath (Join-Path $negativePackage 'UNSIGNED-PREVIEW.txt') `
        -Force
    Assert-Rejected `
        -Description 'Signing a preview whose warning marker was removed' `
        -ExpectedMessage 'Refusing to sign a package containing .cmd:*' `
        -Action {
            & $signScript `
                -PackagePath $negativePackage `
                -SigningCertificatePath $dummyCertificate `
                -SigningCertificatePassword $dummyPassword `
                -ExpectedSignerThumbprint $dummyThumbprint `
                -TimestampServer ''
        }

    Get-ChildItem -LiteralPath $negativePackage -Recurse -File |
        Where-Object Extension -eq '.cmd' |
        Remove-Item -Force
    Assert-Rejected `
        -Description 'Signing a preview with only its BUILD-INFO flag remaining' `
        -ExpectedMessage 'Refusing to sign a package with an invalid installer-batch mode.' `
        -Action {
            & $signScript `
                -PackagePath $negativePackage `
                -SigningCertificatePath $dummyCertificate `
                -SigningCertificatePassword $dummyPassword `
                -ExpectedSignerThumbprint $dummyThumbprint `
                -TimestampServer ''
        }
} finally {
    $expectedNegativePrefix =
        [IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\') + '\'
    foreach ($path in @($negativePackage, $negativeArchive)) {
        $fullPath = [IO.Path]::GetFullPath($path)
        if (-not $fullPath.StartsWith(
            $expectedNegativePrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to clean unexpected negative-test path: $fullPath"
        }
        if (Test-Path -LiteralPath $fullPath) {
            Remove-Item -LiteralPath $fullPath -Recurse -Force
        }
    }
}

Write-Output 'Installer-batch package fail-closed tests passed.'
