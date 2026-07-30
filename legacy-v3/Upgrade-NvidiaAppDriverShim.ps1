[CmdletBinding()]
param(
    [switch]$ElevatedPhase
)

$ErrorActionPreference = 'Stop'

$appExe = 'C:\Program Files\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe'
$profilePath = 'C:\ProgramData\NVIDIA Corporation\NVIDIA App\UpdateFramework\profile-catalog\component_profiles.json'
$localizedConfigPath = 'C:\ProgramData\NVIDIA Corporation\NVIDIA App\NvConfig\LocalizedConfig.json'
$installRoot = Join-Path $env:ProgramData 'NVIDIAAppOCuLinkDriverShim'
$runtimeRoot = Join-Path $installRoot 'runtime'
$statePath = Join-Path $installRoot 'state.json'
$configPath = Join-Path $installRoot 'config.json'
$proxyTarget = Join-Path $installRoot 'proxy.mjs'
$pidPath = Join-Path $runtimeRoot 'shim.pid'
$taskName = 'NVIDIA App OCuLink Driver Shim'
$nvidiaLocalSystemService = 'NvContainerLocalSystem'
$officialBaseUrl = 'https://gfwsl.geforce.com/'
$browserOrigin = 'https://nvfile'
$minimumExpectedVersion = [version]'610.88'
$targetPort = 80
$requiredProxyVersion = 3
$mutexName = 'Global\NVIDIAAppOCuLinkDriverShim-Install'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8NoBom {
    param([string]$LiteralPath, [string]$Value)
    [IO.File]::WriteAllText($LiteralPath, $Value, [Text.UTF8Encoding]::new($false))
}

function Get-LoopbackBaseUrl {
    param(
        [int]$Port,
        [string]$Token
    )

    if ($Port -eq 80) {
        return "http://127.0.0.1/$Token/"
    }
    return "http://127.0.0.1:$Port/$Token/"
}

function ConvertTo-StrictUtcTimestampText {
    param(
        [AllowNull()]
        [object]$Value,
        [string]$Description
    )

    $format = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    if ($Value -is [DateTime]) {
        $dateValue = [DateTime]$Value
        if ($dateValue.Kind -ne [DateTimeKind]::Utc) {
            throw "$Description is not a UTC timestamp."
        }
        return $dateValue.ToString(
            $format,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    if ($Value -is [DateTimeOffset]) {
        $offsetValue = [DateTimeOffset]$Value
        if ($offsetValue.Offset -ne [TimeSpan]::Zero) {
            throw "$Description is not a UTC timestamp."
        }
        return $offsetValue.UtcDateTime.ToString(
            $format,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }

    $textValue = [string]$Value
    $parsedValue = [DateTimeOffset]::MinValue
    if (
        $textValue -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' -or
        -not [DateTimeOffset]::TryParseExact(
            $textValue,
            $format,
            [Globalization.CultureInfo]::InvariantCulture,
            (
                [Globalization.DateTimeStyles]::AssumeUniversal -bor
                [Globalization.DateTimeStyles]::AdjustToUniversal
            ),
            [ref]$parsedValue
        )
    ) {
        throw "$Description is invalid: $textValue"
    }
    return $textValue
}

function Test-SecureInstallRoot {
    param([string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }

    $acl = Get-Acl -LiteralPath $LiteralPath
    if (-not $acl.AreAccessRulesProtected) {
        return $false
    }
    try {
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        return $false
    }
    if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        return $false
    }

    $allowedWriters = @('S-1-5-18', 'S-1-5-32-544')
    $writeMask =
        (
            [int][Security.AccessControl.FileSystemRights]::Write -band
            (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize)
        ) -bor
        [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [int][Security.AccessControl.FileSystemRights]::Delete -bor
        [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [int][Security.AccessControl.FileSystemRights]::TakeOwnership

    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        try {
            $ruleSid = $rule.IdentityReference.Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
        } catch {
            return $false
        }
        if (
            $ruleSid -notin $allowedWriters -and
            (([int]$rule.FileSystemRights -band $writeMask) -ne 0)
        ) {
            return $false
        }
    }
    return $true
}

function Assert-ProtectedFile {
    param([string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected file is a reparse point: $LiteralPath"
    }
    $acl = Get-Acl -LiteralPath $LiteralPath
    $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
    if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw "Unexpected protected file owner: $LiteralPath"
    }

    $allowedWriters = @('S-1-5-18', 'S-1-5-32-544')
    $writeMask =
        (
            [int][Security.AccessControl.FileSystemRights]::Write -band
            (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize)
        ) -bor
        [int][Security.AccessControl.FileSystemRights]::Delete -bor
        [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [int][Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        try {
            $ruleSid = $rule.IdentityReference.Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
        } catch {
            throw "Unable to validate the protected file ACL: $LiteralPath"
        }
        if (
            $ruleSid -notin $allowedWriters -and
            (([int]$rule.FileSystemRights -band $writeMask) -ne 0)
        ) {
            throw "A non-administrator can modify the protected file: $LiteralPath"
        }
    }
}

function Get-RelativeProtectedPath {
    param([string]$RelativePath)

    $rootFull = [IO.Path]::GetFullPath($installRoot).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $installRoot $RelativePath))
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Protected backup path escapes the install directory: $RelativePath"
    }
    return $candidate
}

function Get-ShimTaskAndNodePath {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    try {
        $principalText = [string]$task.Principal.UserId
        if ($principalText -match '^S-\d(?:-\d+)+$') {
            $principalSid = (
                [Security.Principal.SecurityIdentifier]::new($principalText)
            ).Value
        } else {
            $principalSid = (
                [Security.Principal.NTAccount]$principalText
            ).Translate([Security.Principal.SecurityIdentifier]).Value
        }
    } catch {
        throw "Unable to validate the shim task account: $($task.Principal.UserId)"
    }
    if (
        $principalSid -ne 'S-1-5-19' -or
        [string]$task.Principal.LogonType -ne 'ServiceAccount'
    ) {
        throw "Unexpected shim task account: $($task.Principal.UserId)"
    }
    if (@($task.Actions).Count -ne 1) {
        throw 'The shim task has an unexpected number of actions.'
    }
    $nodePath = [Environment]::ExpandEnvironmentVariables(
        [string]$task.Actions[0].Execute
    )
    if (
        -not [IO.Path]::IsPathRooted($nodePath) -or
        -not (Test-Path -LiteralPath $nodePath) -or
        [IO.Path]::GetFileName($nodePath) -ne 'node.exe' -or
        (
            (Get-Item -LiteralPath $nodePath).Attributes -band
            [IO.FileAttributes]::ReparsePoint
        ) -ne 0
    ) {
        throw "The shim task has an unexpected executable: $nodePath"
    }
    $arguments = [string]$task.Actions[0].Arguments
    $expectedArguments = "`"$proxyTarget`" `"$configPath`""
    if ($arguments -ne $expectedArguments) {
        throw 'The shim task action does not reference the protected proxy and config.'
    }
    return [pscustomobject]@{
        Task = $task
        NodePath = $nodePath
    }
}

function Stop-ShimHelper {
    param([string]$NodePath)

    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $pidPath) {
        $pidText = [string](Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue)
        $shimPid = 0
        if ([int]::TryParse($pidText.Trim(), [ref]$shimPid)) {
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$shimPid" -ErrorAction SilentlyContinue
            if (
                $processInfo -and
                [string]::Equals(
                    [IO.Path]::GetFullPath([string]$processInfo.ExecutablePath),
                    [IO.Path]::GetFullPath($NodePath),
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                ([string]$processInfo.CommandLine).Contains($proxyTarget) -and
                ([string]$processInfo.CommandLine).Contains($configPath)
            ) {
                Stop-Process -Id $shimPid -Force -ErrorAction Stop
                Wait-Process -Id $shimPid -Timeout 10 -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-ShimHelper {
    param(
        [Parameter(Mandatory)]
        [string]$NodePath,
        [int]$RequiredVersion = 0
    )

    Start-ScheduledTask -TaskName $taskName
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $baseUrl =
        Get-LoopbackBaseUrl `
            -Port ([int]$config.port) `
            -Token ([string]$config.token)
    $lastHealthError = $null
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri ($baseUrl + 'health') -TimeoutSec 2
            if (
                $health.status -eq 'ok' -and
                [int]$health.port -eq [int]$config.port -and
                ($RequiredVersion -eq 0 -or [int]$health.version -eq $RequiredVersion)
            ) {
                if (-not (Test-Path -LiteralPath $pidPath)) {
                    throw 'The healthy helper did not create its protected PID file.'
                }
                $pidText = [string](Get-Content -LiteralPath $pidPath -Raw)
                $shimPid = 0
                if (
                    -not [int]::TryParse($pidText.Trim(), [ref]$shimPid) -or
                    $shimPid -ne [int]$health.pid
                ) {
                    throw 'The helper health response and PID file do not match.'
                }
                $processInfo =
                    Get-CimInstance `
                        Win32_Process `
                        -Filter "ProcessId=$shimPid" `
                        -ErrorAction Stop
                $owner = Invoke-CimMethod `
                    -InputObject $processInfo `
                    -MethodName GetOwnerSid `
                    -ErrorAction Stop
                if (
                    [int]$owner.ReturnValue -ne 0 -or
                    [string]$owner.Sid -ne 'S-1-5-19' -or
                    -not [string]::Equals(
                        [IO.Path]::GetFullPath([string]$processInfo.ExecutablePath),
                        [IO.Path]::GetFullPath($NodePath),
                        [StringComparison]::OrdinalIgnoreCase
                    ) -or
                    -not ([string]$processInfo.CommandLine).Contains($proxyTarget) -or
                    -not ([string]$processInfo.CommandLine).Contains($configPath)
                ) {
                    throw 'The healthy endpoint is not the scheduled LocalService helper.'
                }
                $listeners = @(
                    Get-NetTCPConnection `
                        -LocalAddress '127.0.0.1' `
                        -LocalPort ([int]$config.port) `
                        -State Listen `
                        -ErrorAction Stop
                )
                if (
                    $listeners.Count -ne 1 -or
                    [int]$listeners[0].OwningProcess -ne $shimPid
                ) {
                    throw 'The LocalService helper does not own the expected loopback listener.'
                }
                return [pscustomobject]@{
                    BaseUrl = $baseUrl
                    Health = $health
                    ProcessId = $shimPid
                }
            }
        } catch {
            $lastHealthError = [string]$_.Exception.Message
        }
        Start-Sleep -Milliseconds 200
    }
    throw "The shim helper did not become healthy at $baseUrl Last check: $lastHealthError"
}

function Stop-CurrentSessionNvidiaProcesses {
    $sessionId = (Get-Process -Id $PID).SessionId
    Get-Process -Name 'NVIDIA App', 'NVIDIA Overlay', 'nvcontainer' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Stop-NvidiaLocalizedConfigService {
    $service = Get-Service -Name $nvidiaLocalSystemService -ErrorAction Stop
    if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $nvidiaLocalSystemService -Force -ErrorAction Stop
        $service = Get-Service -Name $nvidiaLocalSystemService
        $service.WaitForStatus(
            [ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(30)
        )
    }
}

function Start-NvidiaLocalizedConfigService {
    $service = Get-Service -Name $nvidiaLocalSystemService -ErrorAction Stop
    if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
        Start-Service -Name $nvidiaLocalSystemService -ErrorAction Stop
    }
    $service = Get-Service -Name $nvidiaLocalSystemService
    $service.WaitForStatus(
        [ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds(30)
    )
}

function Restart-NvidiaLocalizedConfigService {
    Stop-NvidiaLocalizedConfigService
    Start-NvidiaLocalizedConfigService
}

function Restore-FileAtomically {
    param(
        [string]$TargetPath,
        [string]$SourcePath,
        [string]$OperationName
    )

    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $installRoot "$OperationName.$operationId.tmp"
    $replaceBackup = Join-Path $installRoot "$OperationName.$operationId.rollback"
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $temporaryPath -Force
        $targetAcl = Get-Acl -LiteralPath $TargetPath
        Set-Acl -LiteralPath $temporaryPath -AclObject $targetAcl
        Assert-ProtectedFile -LiteralPath $temporaryPath
        $expectedHash =
            (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        if (
            (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash -ne
            $expectedHash
        ) {
            throw "The protected restore staging copy failed for $TargetPath"
        }
        [IO.File]::Replace($temporaryPath, $TargetPath, $replaceBackup, $true)
        Assert-ProtectedFile -LiteralPath $TargetPath
        if (
            (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash -ne
            $expectedHash
        ) {
            Copy-Item -LiteralPath $replaceBackup -Destination $TargetPath -Force
            throw "Atomic restore verification failed for $TargetPath"
        }
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
    }
}

function Write-ProtectedTextAtomically {
    param(
        [string]$TargetPath,
        [string]$Value,
        [string]$OperationName
    )

    $directory = Split-Path -Parent $TargetPath
    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory "$OperationName.$operationId.tmp"
    $replaceBackup = Join-Path $directory "$OperationName.$operationId.rollback"
    try {
        Write-Utf8NoBom -LiteralPath $temporaryPath -Value $Value
        $targetAcl = Get-Acl -LiteralPath $TargetPath
        Set-Acl -LiteralPath $temporaryPath -AclObject $targetAcl
        Assert-ProtectedFile -LiteralPath $temporaryPath
        $expectedHash =
            (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash
        [IO.File]::Replace($temporaryPath, $TargetPath, $replaceBackup, $true)
        Assert-ProtectedFile -LiteralPath $TargetPath
        if (
            (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash -ne
            $expectedHash
        ) {
            Copy-Item -LiteralPath $replaceBackup -Destination $TargetPath -Force
            throw "Atomic write verification failed for $TargetPath"
        }
        Remove-Item -LiteralPath $replaceBackup -Force
        $replaceBackup = $null
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if ($replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-DriverMetadataPreflight {
    param([string]$BaseUrl)

    $common = [ordered]@{
        gcV = '11.0.8.299'
        lg = '1033'
        gLg = 'en-US'
        dIDa = @('2D04_10DE_2D04_6688_1')
        osC = '10.0.26200'
        dch = '1'
        osB = '8973'
        is6 = '1'
        GFPV = '610.74'
        gIsB = '0'
        iLp = '1'
        isB = '0'
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
    $encoded = [Uri]::EscapeDataString(($common | ConvertTo-Json -Compress))
    $recommendation = Invoke-RestMethod `
        -Uri ($BaseUrl + $recommendationEndpoint + $encoded) `
        -TimeoutSec 40
    $latest = [string]$recommendation.criteria.IsDispDriverNewer.latestDispDriverVersion
    $supported = ([string]$recommendation.criteria.IsSupported.state).ToLowerInvariant()
    $downloadUri = [Uri]$recommendation.DriverAttributes.DownloadURLAdmin
    $recommendationVersionPath = "/Windows/$latest/"
    if (
        $supported -notin @('1', 'true') -or
        [string]::IsNullOrWhiteSpace($latest) -or
        [version]$latest -lt $minimumExpectedVersion -or
        $downloadUri.Scheme -ne 'https' -or
        $downloadUri.Host -notmatch '(^|\.)nvidia\.com$' -or
        $downloadUri.AbsolutePath.IndexOf(
            $recommendationVersionPath,
            [StringComparison]::OrdinalIgnoreCase
        ) -lt 0
    ) {
        throw 'The normalized NVIDIA recommendation metadata preflight failed.'
    }

    $common.GFPV = $latest
    $common.isInst = '0'
    $detailsEndpoint =
        $controller +
        'com.nvidia.services.GFEClientContent_NG.getDispDrvrDtlsByDevid/'
    $detailsEncoded = [Uri]::EscapeDataString(($common | ConvertTo-Json -Compress))
    $detailsUri = $BaseUrl + $detailsEndpoint + $detailsEncoded
    $preflightHeaders = @{
        Origin = $browserOrigin
        'Access-Control-Request-Method' = 'GET'
        'Access-Control-Request-Headers' = 'telemetry,ot-tracer-spanid,x-request-id'
        'Access-Control-Request-Private-Network' = 'true'
    }
    $cors = Invoke-WebRequest `
        -UseBasicParsing `
        -Method Options `
        -Uri $detailsUri `
        -Headers $preflightHeaders `
        -TimeoutSec 10
    if (
        [int]$cors.StatusCode -ne 204 -or
        [string]$cors.Headers['Access-Control-Allow-Origin'] -ne $browserOrigin -or
        [string]$cors.Headers['Access-Control-Allow-Credentials'] -ne 'true' -or
        [string]$cors.Headers['Access-Control-Allow-Private-Network'] -ne 'true' -or
        [string]$cors.Headers['Access-Control-Allow-Methods'] -notmatch '(^|,\s*)GET(\s*,|$)' -or
        [string]$cors.Headers['Access-Control-Allow-Headers'] -notmatch '(^|,\s*)telemetry(\s*,|$)'
    ) {
        throw 'The NVIDIA App CORS/private-network preflight failed.'
    }

    $detailsResponse = Invoke-WebRequest `
        -UseBasicParsing `
        -Method Get `
        -Uri $detailsUri `
        -Headers @{ Origin = $browserOrigin; telemetry = 'shim-preflight' } `
        -TimeoutSec 40
    if (
        [string]$detailsResponse.Headers['Access-Control-Allow-Origin'] -ne $browserOrigin -or
        [string]$detailsResponse.Headers['Access-Control-Allow-Credentials'] -ne 'true'
    ) {
        throw 'The NVIDIA App metadata response is missing required CORS headers.'
    }
    $details = $detailsResponse.Content | ConvertFrom-Json
    $detailsDownload = [Uri][string]$details.DriverAttributes.DownloadURL
    $expectedVersionPath = "/Windows/$latest/"
    $detailsSupported =
        ([string]$details.criteria.IsSupported.state).ToLowerInvariant()
    if (
        $detailsSupported -notin @('1', 'true') -or
        -not $details.DriverAttributes.clientUX -or
        [string]::IsNullOrWhiteSpace([string]$details.DriverAttributes.ID) -or
        [string]::IsNullOrWhiteSpace([string]$details.DriverAttributes.ReleaseDateTime) -or
        $detailsDownload.Scheme -ne 'https' -or
        $detailsDownload.Host -notmatch '(^|\.)nvidia\.com$' -or
        $detailsDownload.AbsolutePath.IndexOf(
            $expectedVersionPath,
            [StringComparison]::OrdinalIgnoreCase
        ) -lt 0
    ) {
        throw "NVIDIA did not return complete details for recommended release $latest."
    }

    return [pscustomobject]@{
        LatestVersion = $latest
        DownloadHost = $downloadUri.Host
        DetailsVersion = $latest
        BrowserOrigin = $browserOrigin
    }
}

if (-not $ElevatedPhase) {
    if (Test-IsAdministrator) {
        throw 'Run this upgrade from a normal, non-administrator PowerShell window.'
    }
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-ElevatedPhase'
    )
    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -Verb RunAs `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    $failureDetail = $null
    if ($process.ExitCode -ne 0) {
        $errorLog = Join-Path $runtimeRoot 'upgrade-error.log'
        $failureDetail = if (Test-Path -LiteralPath $errorLog) {
            Get-Content -LiteralPath $errorLog -Raw
        } else {
            'The elevated phase failed before writing an error log.'
        }
    }
    if (Test-Path -LiteralPath $appExe) {
        Start-Process -FilePath $appExe
    }
    if ($failureDetail) {
        throw "Upgrade failed in the elevated phase.`n$failureDetail"
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Write-Output 'NVIDIA App native and UI driver metadata paths are now redirected.'
    Write-Output "NVIDIA metadata check returned: $($state.verifiedLatestVersion)"
    Write-Output 'No driver package was downloaded or installed.'
    return
}

if (-not (Test-IsAdministrator)) {
    throw 'The elevated phase requires administrator rights.'
}

$mutex = [Threading.Mutex]::new($false, $mutexName)
$lockAcquired = $false
$nodePath = $null
$originalStateText = $null
$state = $null
$proxyBackup = $null
$proxyBackupHash = $null
$temporaryProxy = $null
$proxyAtomicBackup = $null
$configRollbackBackup = $null
$configRollbackHash = $null
$profileRollbackBackup = $null
$profileRollbackHash = $null
$localizedConfigBackup = $null
$localizedConfigRollbackBackup = $null
$proxyMutationAttempted = $false
$configMutationAttempted = $false
$profileMutationAttempted = $false
$localizedConfigReplaced = $false
$localizedConfigServiceStopped = $false
$rollbackSucceeded = $true

try {
    try {
        $lockAcquired = $mutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $lockAcquired = $true
    }
    if (-not $lockAcquired) {
        throw 'Another install, upgrade, or uninstall operation is already running.'
    }
    foreach ($requiredPath in @(
        $installRoot,
        $runtimeRoot,
        $statePath,
        $configPath,
        $proxyTarget,
        $profilePath,
        $localizedConfigPath
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required installed file was not found: $requiredPath"
        }
    }
    if (-not (Test-SecureInstallRoot -LiteralPath $installRoot)) {
        throw "The existing install directory is not trusted: $installRoot"
    }
    foreach ($protectedPath in @(
        $statePath,
        $configPath,
        $proxyTarget,
        $profilePath,
        $localizedConfigPath
    )) {
        Assert-ProtectedFile -LiteralPath $protectedPath
    }
    Remove-Item `
        -LiteralPath (Join-Path $runtimeRoot 'upgrade-error.log') `
        -Force `
        -ErrorAction SilentlyContinue

    $originalStateText = Get-Content -LiteralPath $statePath -Raw
    $state = $originalStateText | ConvertFrom-Json
    if ($state.status -ne 'installed') {
        throw "The shim state is '$($state.status)'; repair or uninstall it before upgrading."
    }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if (
        (
            [int]$config.port -ne 80 -and
            (
                [int]$config.port -lt 1024 -or
                [int]$config.port -gt 65535
            )
        ) -or
        [string]$config.token -notmatch '^[a-f0-9]{32,128}$' -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$config.runtimeDirectory),
            [IO.Path]::GetFullPath($runtimeRoot),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'The protected shim config has an invalid port, token, or runtime directory.'
    }
    $previousLocalBaseUrl =
        Get-LoopbackBaseUrl `
            -Port ([int]$config.port) `
            -Token ([string]$config.token)
    if ($previousLocalBaseUrl -ne [string]$state.localBaseUrl) {
        throw 'The protected config and state contain different loopback URLs.'
    }
    $localBaseUrl =
        Get-LoopbackBaseUrl `
            -Port $targetPort `
            -Token ([string]$config.token)
    $targetConfig = [ordered]@{
        port = $targetPort
        token = [string]$config.token
        runtimeDirectory = $runtimeRoot
    }
    if ([int]$config.port -ne $targetPort) {
        $targetListeners = @(
            Get-NetTCPConnection `
                -LocalPort $targetPort `
                -State Listen `
                -ErrorAction SilentlyContinue
        )
        if ($targetListeners.Count -ne 0) {
            throw "TCP port $targetPort is already in use on 127.0.0.1."
        }
    }

    $profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    foreach ($name in @('grd', 'crd')) {
        $entry = @($profiles | Where-Object componentName -eq $name)
        if ($entry.Count -ne 1 -or -not $entry[0].updateCheckerProfiles) {
            throw "The NVIDIA profile does not contain exactly one usable '$name' entry."
        }
        $currentProfileBase =
            [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl
        if ($currentProfileBase -notin @($previousLocalBaseUrl, $localBaseUrl)) {
            throw "The current '$name' endpoint changed unexpectedly: $currentProfileBase"
        }
    }

    $taskInfo = Get-ShimTaskAndNodePath
    $nodePath = $taskInfo.NodePath
    $proxySource = Join-Path $PSScriptRoot 'proxy.mjs'
    if (-not (Test-Path -LiteralPath $proxySource)) {
        throw "The upgraded proxy source was not found: $proxySource"
    }
    $proxySourceItem = Get-Item -LiteralPath $proxySource
    if (($proxySourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The upgraded proxy source must not be a reparse point.'
    }
    $proxySourceHash =
        (Get-FileHash -LiteralPath $proxySource -Algorithm SHA256).Hash

    $localizedConfigRaw = Get-Content -LiteralPath $localizedConfigPath -Raw
    $localizedConfig = $localizedConfigRaw | ConvertFrom-Json
    $currentLocalizedServer = [string]$localizedConfig.localizedConfig.gfwsl.server
    if (
        $currentLocalizedServer -notin
        @($officialBaseUrl, $previousLocalBaseUrl, $localBaseUrl)
    ) {
        throw "The NVIDIA localized GFWSL endpoint changed unexpectedly: $currentLocalizedServer"
    }
    $currentLocalizedTimestampText =
        ConvertTo-StrictUtcTimestampText `
            -Value $localizedConfig.configTimestamp `
            -Description 'The NVIDIA localized configTimestamp'

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $backupRelativeRoot = Join-Path 'backup' "$timestamp-$backupId-ui-upgrade"
    $backupRoot = Join-Path $installRoot $backupRelativeRoot
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $proxyBackup = Join-Path $backupRoot 'proxy.before-ui-upgrade.mjs'
    Copy-Item -LiteralPath $proxyTarget -Destination $proxyBackup
    Assert-ProtectedFile -LiteralPath $proxyBackup
    $proxyBackupHash = (Get-FileHash -LiteralPath $proxyBackup -Algorithm SHA256).Hash
    if (
        $proxyBackupHash -ne
        (Get-FileHash -LiteralPath $proxyTarget -Algorithm SHA256).Hash
    ) {
        throw 'The transactional proxy backup failed verification.'
    }
    $configRollbackBackup = Join-Path $backupRoot 'config.before-v3-upgrade.json'
    Copy-Item -LiteralPath $configPath -Destination $configRollbackBackup
    Assert-ProtectedFile -LiteralPath $configRollbackBackup
    $configRollbackHash =
        (Get-FileHash -LiteralPath $configRollbackBackup -Algorithm SHA256).Hash
    if (
        $configRollbackHash -ne
        (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    ) {
        throw 'The transactional shim-config backup failed verification.'
    }
    $profileRollbackBackup =
        Join-Path $backupRoot 'component_profiles.before-v3-upgrade.json'
    Copy-Item -LiteralPath $profilePath -Destination $profileRollbackBackup
    Assert-ProtectedFile -LiteralPath $profileRollbackBackup
    $profileRollbackHash =
        (Get-FileHash -LiteralPath $profileRollbackBackup -Algorithm SHA256).Hash
    if (
        $profileRollbackHash -ne
        (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    ) {
        throw 'The transactional NVIDIA-profile backup failed verification.'
    }

    $hasExistingUiBackup =
        $state.PSObject.Properties.Name -contains 'localizedConfigBackupRelative' -and
        -not [string]::IsNullOrWhiteSpace([string]$state.localizedConfigBackupRelative)
    if ($hasExistingUiBackup) {
        $localizedConfigBackup = Get-RelativeProtectedPath `
            -RelativePath ([string]$state.localizedConfigBackupRelative)
        if (-not (Test-Path -LiteralPath $localizedConfigBackup)) {
            throw 'The protected localized-config backup recorded in state is missing.'
        }
        Assert-ProtectedFile -LiteralPath $localizedConfigBackup
        $existingBackupHash = (Get-FileHash -LiteralPath $localizedConfigBackup -Algorithm SHA256).Hash
        if ($existingBackupHash -ne [string]$state.originalLocalizedConfigSha256) {
            throw 'The protected localized-config backup failed its SHA-256 check.'
        }
    } else {
        if ($currentLocalizedServer -ne $officialBaseUrl) {
            throw 'LocalizedConfig is already redirected but no protected original backup exists.'
        }
    }

    Stop-ShimHelper -NodePath $nodePath
    $proxyOperationId = [Guid]::NewGuid().ToString('N')
    $temporaryProxy =
        Join-Path $installRoot "proxy.oculink-upgrade.$proxyOperationId.tmp"
    $proxyAtomicBackup =
        Join-Path $installRoot "proxy.oculink-upgrade.$proxyOperationId.rollback"
    Copy-Item -LiteralPath $proxySource -Destination $temporaryProxy
    $proxyAcl = Get-Acl -LiteralPath $proxyTarget
    Set-Acl -LiteralPath $temporaryProxy -AclObject $proxyAcl
    Assert-ProtectedFile -LiteralPath $temporaryProxy
    if (
        (Get-FileHash -LiteralPath $temporaryProxy -Algorithm SHA256).Hash -ne
        $proxySourceHash
    ) {
        throw 'The protected v3 proxy staging copy failed verification.'
    }
    $proxyMutationAttempted = $true
    [IO.File]::Replace(
        $temporaryProxy,
        $proxyTarget,
        $proxyAtomicBackup,
        $true
    )
    $temporaryProxy = $null
    Assert-ProtectedFile -LiteralPath $proxyTarget
    if (
        (Get-FileHash -LiteralPath $proxyTarget -Algorithm SHA256).Hash -ne
        $proxySourceHash
    ) {
        throw 'The installed v3 proxy failed its SHA-256 copy verification.'
    }
    $configMutationAttempted = $true
    Write-ProtectedTextAtomically `
        -TargetPath $configPath `
        -Value ($targetConfig | ConvertTo-Json -Depth 4) `
        -OperationName 'config.oculink-v3-upgrade'
    $installedConfig =
        Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json
    if (
        [int]$installedConfig.port -ne $targetPort -or
        [string]$installedConfig.token -ne [string]$config.token -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$installedConfig.runtimeDirectory),
            [IO.Path]::GetFullPath($runtimeRoot),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'The installed v3 shim config failed verification.'
    }
    $helper =
        Start-ShimHelper `
            -NodePath $nodePath `
            -RequiredVersion $requiredProxyVersion
    $preflight = Invoke-DriverMetadataPreflight -BaseUrl $helper.BaseUrl

    Stop-CurrentSessionNvidiaProcesses
    $localizedConfigServiceStopped = $true
    Stop-NvidiaLocalizedConfigService

    $profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $profileNeedsChange = $false
    foreach ($name in @('grd', 'crd')) {
        $entry = @($profiles | Where-Object componentName -eq $name)
        if ($entry.Count -ne 1 -or -not $entry[0].updateCheckerProfiles) {
            throw "The live NVIDIA profile does not contain exactly one usable '$name' entry."
        }
        $currentProfileBase =
            [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl
        if ($currentProfileBase -eq $previousLocalBaseUrl) {
            $entry[0].updateCheckerProfiles[0].otaBaseUrl = $localBaseUrl
            $profileNeedsChange = $true
        } elseif ($currentProfileBase -ne $localBaseUrl) {
            throw "The live '$name' endpoint changed during upgrade: $currentProfileBase"
        }
    }
    if ($profileNeedsChange) {
        $profileMutationAttempted = $true
        Write-ProtectedTextAtomically `
            -TargetPath $profilePath `
            -Value ($profiles | ConvertTo-Json -Depth 30) `
            -OperationName 'component_profiles.oculink-v3-upgrade'
    }
    $profileVerification =
        Get-Content -LiteralPath $profilePath -Raw |
        ConvertFrom-Json
    foreach ($name in @('grd', 'crd')) {
        $entry = @($profileVerification | Where-Object componentName -eq $name)
        if (
            $entry.Count -ne 1 -or
            [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl -ne
                $localBaseUrl
        ) {
            throw "The v3 loopback endpoint verification failed for '$name'."
        }
    }

    Assert-ProtectedFile -LiteralPath $localizedConfigPath
    $localizedConfig = Get-Content -LiteralPath $localizedConfigPath -Raw | ConvertFrom-Json
    $liveServerBeforePatch = [string]$localizedConfig.localizedConfig.gfwsl.server
    if (
        $liveServerBeforePatch -notin
        @($officialBaseUrl, $previousLocalBaseUrl, $localBaseUrl)
    ) {
        throw "The NVIDIA localized GFWSL endpoint changed during upgrade: $liveServerBeforePatch"
    }
    $liveTimestampBeforePatchText =
        ConvertTo-StrictUtcTimestampText `
            -Value $localizedConfig.configTimestamp `
            -Description 'The live NVIDIA configTimestamp'

    $localizedConfigRollbackBackup =
        Join-Path $backupRoot 'LocalizedConfig.before-ui-upgrade.json'
    Copy-Item `
        -LiteralPath $localizedConfigPath `
        -Destination $localizedConfigRollbackBackup
    Assert-ProtectedFile -LiteralPath $localizedConfigRollbackBackup
    if (
        (Get-FileHash -LiteralPath $localizedConfigRollbackBackup -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
    ) {
        throw 'The transactional localized-config backup failed verification.'
    }

    if (-not $hasExistingUiBackup) {
        if ($liveServerBeforePatch -ne $officialBaseUrl) {
            throw 'The first UI redirect requires an official live configuration.'
        }
        $localizedConfigBackupRelative =
            Join-Path $backupRelativeRoot 'LocalizedConfig.original.json'
        $localizedConfigBackup = Join-Path $installRoot $localizedConfigBackupRelative
        Copy-Item -LiteralPath $localizedConfigPath -Destination $localizedConfigBackup
        Assert-ProtectedFile -LiteralPath $localizedConfigBackup
        $originalLocalizedConfigSha256 =
            (Get-FileHash -LiteralPath $localizedConfigBackup -Algorithm SHA256).Hash
        $backupVerification =
            Get-Content -LiteralPath $localizedConfigBackup -Raw |
            ConvertFrom-Json
        if (
            [string]$backupVerification.localizedConfig.gfwsl.server -ne
            $officialBaseUrl
        ) {
            throw 'The protected localized-config backup is not an official configuration.'
        }
        $state | Add-Member `
            -NotePropertyName localizedConfigBackupRelative `
            -NotePropertyValue $localizedConfigBackupRelative `
            -Force
        $state | Add-Member `
            -NotePropertyName originalLocalizedConfigSha256 `
            -NotePropertyValue $originalLocalizedConfigSha256 `
            -Force
        $state | Add-Member `
            -NotePropertyName originalLocalizedGfwslServer `
            -NotePropertyValue $officialBaseUrl `
            -Force
    }

    $originalLocalizedConfig =
        Get-Content -LiteralPath $localizedConfigBackup -Raw |
        ConvertFrom-Json
    if (
        [string]$originalLocalizedConfig.localizedConfig.gfwsl.server -ne
        $officialBaseUrl
    ) {
        throw 'The protected localized-config backup is not an official configuration.'
    }
    $originalLocalizedConfigTimestamp =
        ConvertTo-StrictUtcTimestampText `
            -Value $originalLocalizedConfig.configTimestamp `
            -Description 'The protected localized-config backup configTimestamp'

    # NvLocalizedConfig schedules its next remote refresh from the root
    # configTimestamp plus the product-config validity period (currently one
    # day). Keep the cached configuration intact, but move that schedule one
    # year forward so service startup cannot immediately overwrite the
    # loopback GFWSL endpoint.
    $patchedLocalizedConfigTimestamp =
        [DateTime]::UtcNow.AddYears(1).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    $localizedConfig.localizedConfig.gfwsl.server = $localBaseUrl
    $localizedConfig.configTimestamp = $patchedLocalizedConfigTimestamp
    $patchedLocalizedConfigText = $localizedConfig | ConvertTo-Json -Depth 20

    $state.status = 'upgrading'
    if ($previousLocalBaseUrl -ne $localBaseUrl) {
        $state | Add-Member `
            -NotePropertyName endpointMigrationFrom `
            -NotePropertyValue $previousLocalBaseUrl `
            -Force
    }
    $state.localBaseUrl = $localBaseUrl
    $state | Add-Member -NotePropertyName uiRedirectStatus -NotePropertyValue 'installing' -Force
    $state | Add-Member `
        -NotePropertyName proxyVersion `
        -NotePropertyValue $requiredProxyVersion `
        -Force
    $state | Add-Member `
        -NotePropertyName listenerPort `
        -NotePropertyValue $targetPort `
        -Force
    $state | Add-Member `
        -NotePropertyName endpointCompatibility `
        -NotePropertyValue 'implicit-http-default-port' `
        -Force
    $state | Add-Member `
        -NotePropertyName proxySha256 `
        -NotePropertyValue ((Get-FileHash -LiteralPath $proxyTarget -Algorithm SHA256).Hash) `
        -Force
    $state | Add-Member `
        -NotePropertyName configSha256 `
        -NotePropertyValue ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash) `
        -Force
    $state | Add-Member `
        -NotePropertyName patchedProfileSha256 `
        -NotePropertyValue ((Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash) `
        -Force
    $state | Add-Member `
        -NotePropertyName verifiedLatestVersion `
        -NotePropertyValue $preflight.LatestVersion `
        -Force
    $state | Add-Member `
        -NotePropertyName originalLocalizedConfigTimestamp `
        -NotePropertyValue $originalLocalizedConfigTimestamp `
        -Force
    $state | Add-Member `
        -NotePropertyName patchedLocalizedConfigTimestamp `
        -NotePropertyValue $patchedLocalizedConfigTimestamp `
        -Force
    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryLocalizedConfig =
        Join-Path $backupRoot "LocalizedConfig.oculink-upgrade.$operationId.tmp"
    $atomicLocalizedBackup =
        Join-Path $backupRoot "LocalizedConfig.oculink-upgrade.$operationId.rollback"
    try {
        Write-Utf8NoBom `
            -LiteralPath $temporaryLocalizedConfig `
            -Value $patchedLocalizedConfigText
        $localizedAcl = Get-Acl -LiteralPath $localizedConfigPath
        Set-Acl -LiteralPath $temporaryLocalizedConfig -AclObject $localizedAcl
        Assert-ProtectedFile -LiteralPath $temporaryLocalizedConfig
        $expectedPatchedLocalizedHash =
            (Get-FileHash -LiteralPath $temporaryLocalizedConfig -Algorithm SHA256).Hash
        $state | Add-Member `
            -NotePropertyName patchedLocalizedConfigSha256 `
            -NotePropertyValue $expectedPatchedLocalizedHash `
            -Force
        Write-ProtectedTextAtomically `
            -TargetPath $statePath `
            -Value ($state | ConvertTo-Json -Depth 10) `
            -OperationName 'state.oculink-upgrade'
        [IO.File]::Replace(
            $temporaryLocalizedConfig,
            $localizedConfigPath,
            $atomicLocalizedBackup,
            $true
        )
        $localizedConfigReplaced = $true
        Assert-ProtectedFile -LiteralPath $localizedConfigPath
        if (
            (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash -ne
            $expectedPatchedLocalizedHash
        ) {
            throw 'Post-replacement hash verification of LocalizedConfig failed.'
        }
        $postConfig = Get-Content -LiteralPath $localizedConfigPath -Raw | ConvertFrom-Json
        if (
            [string]$postConfig.localizedConfig.gfwsl.server -ne $localBaseUrl -or
            (
                ConvertTo-StrictUtcTimestampText `
                    -Value $postConfig.configTimestamp `
                    -Description 'The installed localized configTimestamp'
            ) -ne
                $patchedLocalizedConfigTimestamp
        ) {
            throw 'Post-replacement verification of LocalizedConfig failed.'
        }
        Remove-Item -LiteralPath $atomicLocalizedBackup -Force
        $atomicLocalizedBackup = $null
    } finally {
        Remove-Item `
            -LiteralPath $temporaryLocalizedConfig `
            -Force `
            -ErrorAction SilentlyContinue
        if ($atomicLocalizedBackup) {
            Remove-Item `
                -LiteralPath $atomicLocalizedBackup `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    Start-NvidiaLocalizedConfigService
    $localizedConfigServiceStopped = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $liveLocalizedHash =
            (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
        if ($liveLocalizedHash -ne $expectedPatchedLocalizedHash) {
            throw 'NvLocalizedConfig changed the localized configuration during service startup.'
        }
        $liveConfig = Get-Content -LiteralPath $localizedConfigPath -Raw | ConvertFrom-Json
        if ([string]$liveConfig.localizedConfig.gfwsl.server -ne $localBaseUrl) {
            throw 'NvLocalizedConfig replaced the loopback endpoint during service startup.'
        }
        if (
            (
                ConvertTo-StrictUtcTimestampText `
                    -Value $liveConfig.configTimestamp `
                    -Description 'The live localized configTimestamp'
            ) -ne
            $patchedLocalizedConfigTimestamp
        ) {
            throw 'NvLocalizedConfig replaced the deferred refresh timestamp during service startup.'
        }
        if ($attempt -lt 29) {
            Start-Sleep -Milliseconds 500
        }
    }
    $localizedService =
        Get-Service -Name $nvidiaLocalSystemService -ErrorAction Stop
    if (
        $localizedService.Status -ne
        [ServiceProcess.ServiceControllerStatus]::Running
    ) {
        throw 'NvContainerLocalSystem did not remain running after localized-config initialization.'
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.status = 'installed'
    $state.uiRedirectStatus = 'installed'
    $state | Add-Member `
        -NotePropertyName patchedLocalizedConfigSha256 `
        -NotePropertyValue $expectedPatchedLocalizedHash `
        -Force
    $state | Add-Member `
        -NotePropertyName uiRedirectInstalledAt `
        -NotePropertyValue (Get-Date).ToString('o') `
        -Force
    Write-ProtectedTextAtomically `
        -TargetPath $statePath `
        -Value ($state | ConvertTo-Json -Depth 10) `
        -OperationName 'state.oculink-installed'
    if ($proxyAtomicBackup) {
        Remove-Item -LiteralPath $proxyAtomicBackup -Force
        $proxyAtomicBackup = $null
    }
    Remove-Item `
        -LiteralPath (Join-Path $runtimeRoot 'upgrade-error.log') `
        -Force `
        -ErrorAction SilentlyContinue
} catch {
    $failure = $_
    if ($nodePath) {
        try {
            Stop-ShimHelper -NodePath $nodePath
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($localizedConfigReplaced -and $localizedConfigRollbackBackup) {
        try {
            if (-not $localizedConfigServiceStopped) {
                $localizedConfigServiceStopped = $true
                Stop-NvidiaLocalizedConfigService
            }
            Restore-FileAtomically `
                -TargetPath $localizedConfigPath `
                -SourcePath $localizedConfigRollbackBackup `
                -OperationName 'LocalizedConfig.oculink-rollback'
            if (
                (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $localizedConfigRollbackBackup -Algorithm SHA256).Hash
            ) {
                throw 'The localized-config rollback failed verification.'
            }
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($profileMutationAttempted -and $profileRollbackBackup) {
        try {
            Restore-FileAtomically `
                -TargetPath $profilePath `
                -SourcePath $profileRollbackBackup `
                -OperationName 'component_profiles.oculink-v3-rollback'
            if (
                (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash -ne
                $profileRollbackHash
            ) {
                throw 'The NVIDIA-profile rollback failed verification.'
            }
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($configMutationAttempted -and $configRollbackBackup) {
        try {
            Restore-FileAtomically `
                -TargetPath $configPath `
                -SourcePath $configRollbackBackup `
                -OperationName 'config.oculink-v3-rollback'
            if (
                (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne
                $configRollbackHash
            ) {
                throw 'The shim-config rollback failed verification.'
            }
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($proxyMutationAttempted -and $proxyBackup) {
        try {
            Restore-FileAtomically `
                -TargetPath $proxyTarget `
                -SourcePath $proxyBackup `
                -OperationName 'proxy.oculink-rollback'
            if (
                (Get-FileHash -LiteralPath $proxyTarget -Algorithm SHA256).Hash -ne
                $proxyBackupHash
            ) {
                throw 'The proxy rollback failed verification.'
            }
        } catch {
            $rollbackSucceeded = $false
        }
    }
    $fileRollbackSucceeded = $rollbackSucceeded
    if ($nodePath) {
        try {
            Start-ShimHelper -NodePath $nodePath | Out-Null
        } catch {
            $rollbackSucceeded = $false
        }
    }
    try {
        if ($rollbackSucceeded -and $originalStateText) {
            Write-ProtectedTextAtomically `
                -TargetPath $statePath `
                -Value $originalStateText `
                -OperationName 'state.oculink-rollback'
        } else {
            $failureState = if ($fileRollbackSucceeded -and $originalStateText) {
                $originalStateText | ConvertFrom-Json
            } else {
                $state
            }
            if (-not $failureState) {
                throw 'Unable to construct a protected rollback-required state.'
            }
            $failureState.status = 'upgrading'
            $hasRecordedLocalizedBackup = (
                $failureState.PSObject.Properties.Name -contains 'localizedConfigBackupRelative' -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$failureState.localizedConfigBackupRelative
                )
            )
            if ($hasRecordedLocalizedBackup) {
                $failureState | Add-Member `
                    -NotePropertyName uiRedirectStatus `
                    -NotePropertyValue 'rollback-required' `
                    -Force
            } elseif (
                $failureState.PSObject.Properties.Name -contains
                'uiRedirectStatus'
            ) {
                $failureState.PSObject.Properties.Remove('uiRedirectStatus')
            }
            $failureState | Add-Member `
                -NotePropertyName upgradeFailure `
                -NotePropertyValue ([string]$failure.Exception.Message) `
                -Force
            Write-ProtectedTextAtomically `
                -TargetPath $statePath `
                -Value ($failureState | ConvertTo-Json -Depth 10) `
                -OperationName 'state.oculink-rollback-required'
        }
    } catch {
        $rollbackSucceeded = $false
    }
    if ($localizedConfigServiceStopped) {
        try {
            Start-NvidiaLocalizedConfigService
            $localizedConfigServiceStopped = $false
        } catch {
            $rollbackSucceeded = $false
        }
    }
    foreach ($cleanupPath in @($temporaryProxy, $proxyAtomicBackup)) {
        if ($cleanupPath) {
            Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Path $runtimeRoot -Force -ErrorAction SilentlyContinue | Out-Null
    try {
        $failureText = ($failure | Out-String)
        if (-not $rollbackSucceeded) {
            $failureText += "`r`nAutomatic rollback was incomplete; run the uninstaller before retrying."
        }
        Write-Utf8NoBom `
            -LiteralPath (Join-Path $runtimeRoot 'upgrade-error.log') `
            -Value $failureText
    } catch {
        # The parent process will still receive a non-zero exit code.
    }
    throw $failure
} finally {
    if ($lockAcquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
