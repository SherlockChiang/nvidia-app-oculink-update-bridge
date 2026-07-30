[CmdletBinding()]
param(
    [string]$Version = '4.0.0',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$project =
    Join-Path $repositoryRoot 'src\NvidiaAppOculinkShim\NvidiaAppOculinkShim.csproj'
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$publishRoot = Join-Path $artifactsRoot 'publish\win-x64'
$packageName = "NvidiaAppOculinkUpdateBridge-$Version-win-x64"
$packageRoot = Join-Path $artifactsRoot (Join-Path 'package' $packageName)
$payloadRoot = Join-Path $packageRoot 'payload'
$archivePath = Join-Path $artifactsRoot ($packageName + '.zip')
$continuousIntegrationBuild =
    if ($env:GITHUB_ACTIONS -eq 'true') { 'true' } else { 'false' }

& (Join-Path $PSScriptRoot 'Assert-SemVer.ps1') -Version $Version |
    Out-Null

if (-not $SkipBuild) {
    if (Test-Path -LiteralPath $publishRoot) {
        $resolvedPublishRoot = (Resolve-Path -LiteralPath $publishRoot).Path
        $expectedPublishParent =
            (Join-Path $artifactsRoot 'publish').TrimEnd('\') + '\'
        if (-not $resolvedPublishRoot.StartsWith(
            $expectedPublishParent,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to replace unexpected publish directory: $resolvedPublishRoot"
        }
        Remove-Item -LiteralPath $resolvedPublishRoot -Recurse -Force
    }

    dotnet publish $project `
        -c Release `
        -r win-x64 `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:PublishTrimmed=false `
        -p:Version=$Version `
        -p:ContinuousIntegrationBuild=$continuousIntegrationBuild `
        -o $publishRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'dotnet publish failed.'
    }
}

$serviceBinary = Join-Path $publishRoot 'NvidiaAppOculinkShim.exe'
if (-not (Test-Path -LiteralPath $serviceBinary -PathType Leaf)) {
    throw "Published service binary is missing: $serviceBinary"
}

if (Test-Path -LiteralPath $packageRoot) {
    $resolved = (Resolve-Path -LiteralPath $packageRoot).Path
    $expectedParent =
        (Join-Path $artifactsRoot 'package').TrimEnd('\') + '\'
    if (-not $resolved.StartsWith(
        $expectedParent,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to replace unexpected package directory: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
Copy-Item -LiteralPath $serviceBinary -Destination $payloadRoot
$installerFiles = @(
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
    'Uninstall-NvidiaAppOculinkShim.ps1'
)
foreach ($installerFile in $installerFiles) {
    Copy-Item `
        -LiteralPath (Join-Path $repositoryRoot (Join-Path 'installer' $installerFile)) `
        -Destination $packageRoot
}
Copy-Item `
    -LiteralPath (Join-Path $repositoryRoot 'README.md') `
    -Destination $packageRoot
foreach ($publicFile in @(
    'README.zh-CN.md',
    'LICENSE',
    'SECURITY.md',
    'CHANGELOG.md'
)) {
    Copy-Item `
        -LiteralPath (Join-Path $repositoryRoot $publicFile) `
        -Destination $packageRoot
}
Copy-Item `
    -LiteralPath (Join-Path $repositoryRoot 'docs') `
    -Destination $packageRoot `
    -Recurse

$sourceCommit = (
    git -c "safe.directory=$($repositoryRoot.Replace('\', '/'))" `
        -C $repositoryRoot rev-parse HEAD
).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[a-f0-9]{40}$') {
    throw 'Unable to determine the source Git commit.'
}
$dotnetSdk = (dotnet --version).Trim()
if ($LASTEXITCODE -ne 0 -or $dotnetSdk -notmatch '^\d+\.\d+\.\d+') {
    throw 'Unable to determine the .NET SDK version.'
}
[IO.File]::WriteAllLines(
    (Join-Path $packageRoot 'BUILD-INFO.txt'),
    @(
        "Version: $Version",
        "Source-Commit: $sourceCommit",
        "Dotnet-SDK: $dotnetSdk",
        'Runtime: win-x64 self-contained',
        'Driver-Payloads-Included: false'
    ),
    [Text.UTF8Encoding]::new($false)
)

& (Join-Path $PSScriptRoot 'Finalize-Package.ps1') `
    -PackagePath $packageRoot `
    -ArchivePath $archivePath
