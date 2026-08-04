[CmdletBinding()]
param(
    [switch]$ElevatedPhase,
    [string]$ServiceBinary
)

$ErrorActionPreference = 'Stop'
$programData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData
)
$installRoot = Join-Path $programData 'NVIDIAAppOCuLinkDriverShim'
$statePath = Join-Path $installRoot 'state.json'
$maintenanceArguments = @{}
if ($ElevatedPhase) {
    if ([string]::IsNullOrWhiteSpace($ServiceBinary)) {
        $ServiceBinary =
            Join-Path $PSScriptRoot 'payload\NvidiaAppOculinkShim.exe'
    }
    $maintenanceArguments.ElevatedPhase = $true
    $maintenanceArguments.ServiceBinary = $ServiceBinary
} elseif (-not [string]::IsNullOrWhiteSpace($ServiceBinary)) {
    $maintenanceArguments.ServiceBinary = $ServiceBinary
}

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    & (Join-Path $PSScriptRoot 'Install-NvidiaAppOculinkShim.ps1') `
        @maintenanceArguments
    return
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.status -eq 'uninstalled') {
    & (Join-Path $PSScriptRoot 'Install-NvidiaAppOculinkShim.ps1') `
        @maintenanceArguments
    return
}
if ($state.status -ne 'installed') {
    throw "Setup cannot continue while protected state is '$($state.status)'."
}
if ([int]$state.proxyVersion -eq 3) {
    & (Join-Path $PSScriptRoot 'Migrate-V3ToV4.ps1') `
        @maintenanceArguments
    return
}
if (
    [int]$state.proxyVersion -eq 4 -and
    [string]$state.hostKind -eq 'windows-service'
) {
    & (Join-Path $PSScriptRoot 'Repair-NvidiaAppOculinkShim.ps1') `
        @maintenanceArguments
    return
}
throw "Setup does not recognize installed proxy version '$($state.proxyVersion)'."
