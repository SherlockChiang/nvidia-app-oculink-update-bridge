[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path `
    $repositoryRoot `
    "src\NvidiaAppOculinkShim\bin\$Configuration\net10.0\NvidiaAppOculinkShim.exe"
$runtimeDirectory = Join-Path $repositoryRoot 'artifacts\integration-runtime'
$configPath = Join-Path $runtimeDirectory 'config.json'
$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()
$token = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$baseUrl = "http://127.0.0.1:$port/$token/"
$process = $null

if (-not (Test-Path -LiteralPath $executable)) {
    throw "Build the service before running integration tests: $executable"
}

New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
$config = [ordered]@{
    port = $port
    token = $token
    runtimeDirectory = $runtimeDirectory
}
[IO.File]::WriteAllText(
    $configPath,
    ($config | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)

try {
    $process = Start-Process `
        -FilePath $executable `
        -ArgumentList @('--config', "`"$configPath`"") `
        -WindowStyle Hidden `
        -PassThru

    $health = $null
    foreach ($attempt in 1..40) {
        try {
            $health = Invoke-RestMethod -Uri ($baseUrl + 'health') -TimeoutSec 2
            if ($health.status -eq 'ok') {
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if ($health.status -ne 'ok' -or [int]$health.version -ne 4) {
        throw 'The isolated v4 helper did not become healthy.'
    }

    $payload = [ordered]@{
        gcV = '11.0.8.299'
        lg = '1033'
        gLg = 'en-US'
        dIDa = @('2D04_10DE_2D04_6688_1')
        osC = '10.0.26200'
        osB = '8973'
        is6 = '1'
        GFPV = '610.74'
        dch = '1'
        iLp = '1'
        isB = '0'
        gIsB = '0'
        isO = '1'
        go = 'US'
        prvMd = '0'
        cSR = '0'
        IsQ = '0'
        uCst = '0'
        upCRD = '0'
        isCRD = '0'
        isInst = '1'
    }
    $controller = 'nvidia_web_services/controller.gfeclientcontent.NG.php/'
    $recommendationEndpoint =
        $controller +
        'com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/'
    $detailsEndpoint =
        $controller +
        'com.nvidia.services.GFEClientContent_NG.getDispDrvrDtlsByDevid/'
    $encoded = [Uri]::EscapeDataString(($payload | ConvertTo-Json -Compress))
    $recommendation = Invoke-RestMethod `
        -Uri ($baseUrl + $recommendationEndpoint + $encoded) `
        -TimeoutSec 40
    $latestVersion =
        [string]$recommendation.criteria.IsDispDriverNewer.latestDispDriverVersion
    $recommendationUri = [Uri]$recommendation.DriverAttributes.DownloadURLAdmin
    if (
        [string]::IsNullOrWhiteSpace($latestVersion) -or
        $recommendationUri.Scheme -ne 'https' -or
        $recommendationUri.Host -notmatch '(^|\.)nvidia\.com$'
    ) {
        throw 'NVIDIA returned an invalid recommendation.'
    }

    $payload.GFPV = $latestVersion
    $payload.isInst = '0'
    $detailsUrl =
        $baseUrl +
        $detailsEndpoint +
        [Uri]::EscapeDataString(($payload | ConvertTo-Json -Compress))
    $preflight = Invoke-WebRequest `
        -Method Options `
        -Uri $detailsUrl `
        -Headers @{
            Origin = 'https://nvfile'
            'Access-Control-Request-Method' = 'GET'
            'Access-Control-Request-Headers' = 'telemetry,x-request-id'
            'Access-Control-Request-Private-Network' = 'true'
        }
    if (
        [int]$preflight.StatusCode -ne 204 -or
        $preflight.Headers['Access-Control-Allow-Origin'] -ne 'https://nvfile' -or
        $preflight.Headers['Access-Control-Allow-Private-Network'] -ne 'true'
    ) {
        throw 'CORS/PNA preflight failed.'
    }

    $detailsResponse = Invoke-WebRequest `
        -Uri $detailsUrl `
        -Headers @{ Origin = 'https://nvfile'; telemetry = 'v4-integration' }
    $details = $detailsResponse.Content | ConvertFrom-Json
    $detailsUri = [Uri]$details.DriverAttributes.DownloadURL
    if (
        [int]$detailsResponse.StatusCode -ne 200 -or
        [string]::IsNullOrWhiteSpace([string]$details.DriverAttributes.ID) -or
        $detailsUri.Host -notmatch '(^|\.)nvidia\.com$'
    ) {
        throw 'NVIDIA returned invalid driver details.'
    }

    $forbiddenStatus = 0
    try {
        Invoke-WebRequest `
            -Uri $detailsUrl `
            -Headers @{ Origin = 'https://example.invalid' } `
            -ErrorAction Stop | Out-Null
    } catch {
        $forbiddenStatus = [int]$_.Exception.Response.StatusCode
    }
    if ($forbiddenStatus -ne 403) {
        throw 'An untrusted browser origin was not rejected.'
    }

    $blockedStatus = 0
    try {
        Invoke-WebRequest -Uri ($baseUrl + 'not-allowed') -ErrorAction Stop |
            Out-Null
    } catch {
        $blockedStatus = [int]$_.Exception.Response.StatusCode
    }
    if ($blockedStatus -ne 404) {
        throw 'An unrelated path was not rejected.'
    }

    [pscustomobject]@{
        Health = $health.status
        ProxyVersion = $health.version
        LatestVersion = $latestVersion
        RecommendationHost = $recommendationUri.Host
        CorsOrigin = $preflight.Headers['Access-Control-Allow-Origin']
        PrivateNetwork = $preflight.Headers['Access-Control-Allow-Private-Network']
        DetailsId = $details.DriverAttributes.ID
        DetailsHost = $detailsUri.Host
        ForbiddenOriginStatus = $forbiddenStatus
        BlockedPathStatus = $blockedStatus
    }
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
}
