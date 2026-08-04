[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$programData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData
)
$installRoot = Join-Path $programData 'NVIDIAAppOCuLinkDriverShim'
$statePath = Join-Path $installRoot 'state.json'
$configPath = Join-Path $installRoot 'config.json'
$profilePath = Join-Path $programData (
    'NVIDIA Corporation\NVIDIA App\UpdateFramework\' +
    'profile-catalog\component_profiles.json'
)
$localizedConfigPath = Join-Path $programData (
    'NVIDIA Corporation\NVIDIA App\NvConfig\LocalizedConfig.json'
)
$serviceName = 'NvidiaAppOculinkShim'

try {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $baseUrl = if ([int]$config.port -eq 80) {
        "http://127.0.0.1/$($config.token)/"
    } else {
        "http://127.0.0.1:$($config.port)/$($config.token)/"
    }
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $health = Invoke-RestMethod -Uri ($baseUrl + 'health') -TimeoutSec 5
    $profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $localized =
        Get-Content -LiteralPath $localizedConfigPath -Raw |
        ConvertFrom-Json
    $profileOk = @('grd', 'crd') | ForEach-Object {
        $entry = @($profiles | Where-Object componentName -eq $_)
        $entry.Count -eq 1 -and
        [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl -eq $baseUrl
    }
    $profileRedirectOk = $false -notin $profileOk
    $localizedRedirectOk =
        [string]$localized.localizedConfig.gfwsl.server -eq $baseUrl
    $healthy =
        $state.status -eq 'installed' -and
        [int]$state.proxyVersion -eq 4 -and
        $service.Status -eq 'Running' -and
        $health.status -eq 'ok' -and
        $profileRedirectOk -and
        $localizedRedirectOk

    [pscustomobject]@{
        Overall = if ($healthy) { 'Normal' } else { 'Needs repair' }
        Service = [string]$service.Status
        ProxyVersion = [int]$health.version
        ProfileRedirect = $profileRedirectOk
        LocalizedRedirect = $localizedRedirectOk
        LastVerifiedDriver = [string]$state.verifiedLatestVersion
        RuntimeLog = Join-Path $installRoot 'runtime\shim.log'
    } | Format-List
    if (-not $healthy) {
        exit 2
    }
} catch {
    Write-Error $_
    Write-Output (
        'Run the package Setup entry point to install or repair the bridge.'
    )
    exit 1
}
