[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $repositoryRoot (
    'src\NvidiaAppOculinkLauncher\bin\' +
    $Configuration +
    '\net10.0-windows\win-x64\NvidiaAppOculinkUpdateBridge.dll'
)
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "The launcher build output is missing: $launcherPath"
}

& dotnet $launcherPath --self-test
if ($LASTEXITCODE -ne 0) {
    throw "Launcher self-test failed with exit code $LASTEXITCODE."
}

Write-Output 'Launcher deterministic self-test passed under the build host.'
