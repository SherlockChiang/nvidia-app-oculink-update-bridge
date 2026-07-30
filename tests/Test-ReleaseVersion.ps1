[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$assertVersion = Join-Path $repositoryRoot 'build\Assert-SemVer.ps1'
$validVersions = @(
    '0.0.0',
    '4.0.0',
    '4.0.0-alpha.1',
    '4.0.0+build.1',
    '4.0.0-rc.1+build.20260803'
)
$invalidVersions = @(
    '01.0.0',
    '4.0',
    '4.0.0-.',
    '4.0.0-alpha..1',
    'v4.0.0'
)

foreach ($version in $validVersions) {
    & $assertVersion -Version $version | Out-Null
}
foreach ($version in $invalidVersions) {
    $rejected = $false
    try {
        & $assertVersion -Version $version | Out-Null
    } catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Invalid version was accepted: $version"
    }
}

Write-Output 'SemVer validation tests passed.'
