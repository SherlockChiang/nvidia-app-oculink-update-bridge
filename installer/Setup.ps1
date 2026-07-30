[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installRoot = Join-Path $env:ProgramData 'NVIDIAAppOCuLinkDriverShim'
$statePath = Join-Path $installRoot 'state.json'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    & (Join-Path $PSScriptRoot 'Install-NvidiaAppOculinkShim.ps1')
    return
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.status -eq 'uninstalled') {
    & (Join-Path $PSScriptRoot 'Install-NvidiaAppOculinkShim.ps1')
    return
}
if ($state.status -ne 'installed') {
    throw "Setup cannot continue while protected state is '$($state.status)'."
}
if ([int]$state.proxyVersion -eq 3) {
    & (Join-Path $PSScriptRoot 'Migrate-V3ToV4.ps1')
    return
}
if (
    [int]$state.proxyVersion -eq 4 -and
    [string]$state.hostKind -eq 'windows-service'
) {
    & (Join-Path $PSScriptRoot 'Repair-NvidiaAppOculinkShim.ps1')
    return
}
throw "Setup does not recognize installed proxy version '$($state.proxyVersion)'."

