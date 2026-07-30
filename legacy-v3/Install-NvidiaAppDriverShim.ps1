[CmdletBinding()]
param(
    [int]$Port = 80,
    [switch]$ElevatedPhase
)

$ErrorActionPreference = 'Stop'

$appExe = 'C:\Program Files\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe'
$profilePath = 'C:\ProgramData\NVIDIA Corporation\NVIDIA App\UpdateFramework\profile-catalog\component_profiles.json'
$installRoot = Join-Path $env:ProgramData 'NVIDIAAppOCuLinkDriverShim'
$runtimeRoot = Join-Path $installRoot 'runtime'
$statePath = Join-Path $installRoot 'state.json'
$configPath = Join-Path $installRoot 'config.json'
$proxyTarget = Join-Path $installRoot 'proxy.mjs'
$pidPath = Join-Path $runtimeRoot 'shim.pid'
$taskName = 'NVIDIA App OCuLink Driver Shim'
$officialBaseUrl = 'https://gfwsl.geforce.com/'
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

function ConvertTo-HexString {
    param([byte[]]$Bytes)
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
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
    # ReadAndExecute and Write both include Synchronize. Exclude that shared
    # bit so a read-only rule is not misclassified as writable.
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

function Set-SecureInstallRoot {
    param([string]$LiteralPath)

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $localService = [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $acl.SetOwner($administrators)
    foreach ($sid in @($system, $administrators)) {
        $acl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow
            )
        )
    }
    foreach ($sid in @($localService, $users)) {
        $acl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                $inheritance,
                $propagation,
                $allow
            )
        )
    }
    Set-Acl -LiteralPath $LiteralPath -AclObject $acl
}

function Protect-InstallTree {
    param([string]$LiteralPath)

    Set-SecureInstallRoot -LiteralPath $LiteralPath
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    Get-ChildItem -LiteralPath $LiteralPath -Recurse -Force |
        Where-Object {
            -not $_.FullName.StartsWith(
                ($runtimeRoot.TrimEnd('\') + '\'),
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            -not [string]::Equals(
                $_.FullName,
                $runtimeRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        } |
        ForEach-Object {
        $itemAcl = Get-Acl -LiteralPath $_.FullName
        $itemAcl.SetAccessRuleProtection($false, $true)
        $itemAcl.SetOwner($administrators)
        Set-Acl -LiteralPath $_.FullName -AclObject $itemAcl
    }
}

function Set-SecureRuntimeRoot {
    param([string]$LiteralPath)

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $localService = [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl.SetOwner($administrators)

    foreach ($sid in @($system, $administrators)) {
        $acl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow
            )
        )
    }
    $acl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $localService,
            [Security.AccessControl.FileSystemRights]::Modify,
            $inheritance,
            $propagation,
            $allow
        )
    )
    $acl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $users,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            $propagation,
            $allow
        )
    )
    Set-Acl -LiteralPath $LiteralPath -AclObject $acl
}

function Stop-ShimTaskAndProcess {
    try {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    } catch {
        # The task may already be stopped.
    }

    if (Test-Path -LiteralPath $pidPath) {
        $pidText = [string](Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue)
        $shimPid = 0
        if ([int]::TryParse($pidText.Trim(), [ref]$shimPid)) {
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$shimPid" -ErrorAction SilentlyContinue
            if (
                $processInfo -and
                [string]::Equals(
                    [IO.Path]::GetFullPath([string]$processInfo.ExecutablePath),
                    [IO.Path]::GetFullPath($nodePath),
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                ([string]$processInfo.CommandLine).Contains($proxyTarget) -and
                ([string]$processInfo.CommandLine).Contains($configPath)
            ) {
                Stop-Process -Id $shimPid -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ShimMetadata {
    param([string]$BaseUrl)

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
        prvMd = '0'
        IsQ = '0'
        upCRD = '0'
        isCRD = '0'
        isInst = '1'
    }
    $encoded = [Uri]::EscapeDataString(($payload | ConvertTo-Json -Compress))
    $endpoint = 'nvidia_web_services/controller.gfeclientcontent.NG.php/com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/'
    return Invoke-RestMethod -Uri ($BaseUrl + $endpoint + $encoded) -TimeoutSec 40
}

function Stop-CurrentSessionNvidiaProcesses {
    $sessionId = (Get-Process -Id $PID).SessionId
    Get-Process -Name 'NVIDIA App', 'NVIDIA Overlay', 'nvcontainer' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Port -ne 80 -and ($Port -lt 1024 -or $Port -gt 65535)) {
    throw 'Port must be 80 or between 1024 and 65535.'
}

if (-not $ElevatedPhase) {
    if (Test-IsAdministrator) {
        throw 'Run this installer from a normal, non-administrator PowerShell window. It will request only the elevation it needs.'
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Port', $Port,
        '-ElevatedPhase'
    )
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        $errorLog = Join-Path $runtimeRoot 'install-error.log'
        $detail = if (Test-Path -LiteralPath $errorLog) {
            Get-Content -LiteralPath $errorLog -Raw
        } else {
            'The elevated phase failed before writing an error log.'
        }
        throw "Installation failed in the elevated phase.`n$detail"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $baseUrl =
        Get-LoopbackBaseUrl `
            -Port ([int]$config.port) `
            -Token ([string]$config.token)
    $health = Invoke-RestMethod -Uri ($baseUrl + 'health') -TimeoutSec 5
    if ($health.status -ne 'ok') {
        throw 'The installed helper is not healthy.'
    }

    Start-Process -FilePath "$env:WINDIR\explorer.exe" -ArgumentList "`"$appExe`""
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Write-Output 'Installed the NVIDIA App OCuLink driver metadata shim.'
    Write-Output "NVIDIA metadata check returned: $($state.verifiedLatestVersion)"
    Write-Output "Protected backup: $(Join-Path $installRoot $state.profileBackupRelative)"
    Write-Output "Runtime log: $(Join-Path $runtimeRoot 'shim.log')"
    Write-Output 'No graphics driver was downloaded or installed.'
    return
}

if (-not (Test-IsAdministrator)) {
    throw 'The elevated phase requires administrator rights.'
}

$mutex = [Threading.Mutex]::new($false, $mutexName)
$lockAcquired = $false
$taskRegistered = $false
$profileReplaced = $false
$temporaryProfile = $null
$atomicBackup = $null
$profileBackup = $null
$originalProfileHash = $null
$state = $null
$nodePath = $null
$installRootTrusted = $false

try {
    $lockAcquired = $mutex.WaitOne(0)
    if (-not $lockAcquired) {
        throw 'Another install or uninstall operation is already running.'
    }
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "NVIDIA App update profile was not found: $profilePath"
    }
    if (-not (Test-Path -LiteralPath $appExe)) {
        throw "NVIDIA App executable was not found: $appExe"
    }

    $nodePath = (Get-Command node.exe -ErrorAction Stop).Source
    $nodeVersion = (& $nodePath --version).TrimStart('v')
    if ([version]$nodeVersion -lt [version]'18.0') {
        throw "Node.js 18 or newer is required; found $nodeVersion."
    }

    if (Test-Path -LiteralPath $installRoot) {
        if (-not (Test-SecureInstallRoot -LiteralPath $installRoot)) {
            throw "The existing install directory is not trusted: $installRoot"
        }
        $installRootTrusted = $true
        if (-not (Test-Path -LiteralPath $statePath)) {
            throw 'The protected install directory exists without state; review it before reinstalling.'
        }
        $existingState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($existingState.status -ne 'uninstalled') {
            throw "The shim state is '$($existingState.status)'. Run the uninstaller before reinstalling."
        }
    } else {
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        Set-SecureInstallRoot -LiteralPath $installRoot
        $installRootTrusted = $true
    }

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw "The scheduled task '$taskName' already exists."
    }

    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    Set-SecureRuntimeRoot -LiteralPath $runtimeRoot
    Remove-Item -LiteralPath (Join-Path $runtimeRoot 'install-error.log') -Force -ErrorAction SilentlyContinue

    $proxySource = Join-Path $PSScriptRoot 'proxy.mjs'
    if (-not (Test-Path -LiteralPath $proxySource)) {
        throw "Proxy source was not found: $proxySource"
    }
    Copy-Item -LiteralPath $proxySource -Destination $proxyTarget -Force

    $tokenBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($tokenBytes)
    } finally {
        $rng.Dispose()
    }
    $token = ConvertTo-HexString -Bytes $tokenBytes
    $localBaseUrl = Get-LoopbackBaseUrl -Port $Port -Token $token
    $config = [ordered]@{
        port = $Port
        token = $token
        runtimeDirectory = $runtimeRoot
    }
    Write-Utf8NoBom -LiteralPath $configPath -Value ($config | ConvertTo-Json -Depth 4)
    Protect-InstallTree -LiteralPath $installRoot
    Set-SecureRuntimeRoot -LiteralPath $runtimeRoot

    $action = New-ScheduledTaskAction -Execute $nodePath -Argument "`"$proxyTarget`" `"$configPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $localServiceName = (
        [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
    ).Translate([Security.Principal.NTAccount]).Value
    $principal = New-ScheduledTaskPrincipal -UserId $localServiceName -LogonType ServiceAccount -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Loopback-only NVIDIA driver metadata normalizer for an OCuLink desktop GPU.' | Out-Null
    $taskRegistered = $true

    $registeredTask = Get-ScheduledTask -TaskName $taskName
    $registeredPrincipalSid = (
        [Security.Principal.NTAccount]$registeredTask.Principal.UserId
    ).Translate([Security.Principal.SecurityIdentifier]).Value
    if (
        $registeredPrincipalSid -ne 'S-1-5-19' -or
        [string]$registeredTask.Principal.LogonType -ne 'ServiceAccount'
    ) {
        throw 'The helper task was not registered as the low-privilege LocalService account.'
    }
    Start-ScheduledTask -TaskName $taskName

    $health = $null
    foreach ($attempt in 1..40) {
        try {
            $health = Invoke-RestMethod -Uri ($localBaseUrl + 'health') -TimeoutSec 2
            if ($health.status -eq 'ok') {
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $health -or $health.status -ne 'ok') {
        throw 'The limited-token loopback helper did not become healthy.'
    }
    $helperProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($health.pid)" -ErrorAction Stop
    $helperOwner = Invoke-CimMethod -InputObject $helperProcessInfo -MethodName GetOwnerSid
    if (
        $helperOwner.ReturnValue -ne 0 -or
        [string]$helperOwner.Sid -ne 'S-1-5-19' -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$helperProcessInfo.ExecutablePath),
            [IO.Path]::GetFullPath($nodePath),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not ([string]$helperProcessInfo.CommandLine).Contains($proxyTarget) -or
        -not ([string]$helperProcessInfo.CommandLine).Contains($configPath)
    ) {
        throw 'The helper process identity or command line did not match the protected LocalService task.'
    }

    $metadata = Get-ShimMetadata -BaseUrl $localBaseUrl
    $supported = ([string]$metadata.criteria.IsSupported.state).ToLowerInvariant()
    $latestText = [string]$metadata.criteria.IsDispDriverNewer.latestDispDriverVersion
    $downloadUri = [Uri]$metadata.DriverAttributes.DownloadURLAdmin
    if ($supported -notin @('1', 'true')) {
        throw 'The NVIDIA metadata endpoint did not mark this GPU as supported.'
    }
    if ([version]$latestText -le [version]'610.74') {
        throw "The NVIDIA metadata preflight did not return a newer driver: $latestText"
    }
    if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -notmatch '(^|\.)nvidia\.com$') {
        throw "The NVIDIA metadata preflight returned an unexpected download host: $downloadUri"
    }

    # Windows PowerShell 5.1 emits a top-level JSON array as one pipeline item.
    # Assign directly so foreach receives the actual profile elements.
    $profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $changedComponents = @()
    foreach ($profile in $profiles) {
        if ($profile.componentName -in @('grd', 'crd')) {
            if (-not $profile.updateCheckerProfiles -or $profile.updateCheckerProfiles.Count -lt 1) {
                throw "NVIDIA component '$($profile.componentName)' has no update checker profile."
            }
            $currentBase = [string]$profile.updateCheckerProfiles[0].otaBaseUrl
            if ($currentBase -ne $officialBaseUrl) {
                throw "Unexpected NVIDIA OTA base URL for '$($profile.componentName)': $currentBase"
            }
            $profile.updateCheckerProfiles[0].otaBaseUrl = $localBaseUrl
            $changedComponents += $profile.componentName
        }
    }
    if (@($changedComponents | Sort-Object -Unique).Count -ne 2) {
        throw 'Expected exactly one grd and one crd component profile.'
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRelative = Join-Path (Join-Path 'backup' $timestamp) 'component_profiles.json'
    $profileBackup = Join-Path $installRoot $backupRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $profileBackup) -Force | Out-Null
    Copy-Item -LiteralPath $profilePath -Destination $profileBackup
    $originalProfileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $profileBackup -Algorithm SHA256).Hash -ne $originalProfileHash) {
        throw 'The protected NVIDIA profile backup failed verification.'
    }

    $state = [ordered]@{
        status = 'installing'
        installedAt = (Get-Date).ToString('o')
        profileBackupRelative = $backupRelative
        originalProfileSha256 = $originalProfileHash
        patchedProfileSha256 = $null
        localBaseUrl = $localBaseUrl
        verifiedLatestVersion = $latestText
        proxyVersion = 3
        proxySha256 = (Get-FileHash -LiteralPath $proxyTarget -Algorithm SHA256).Hash
        configSha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
        listenerPort = $Port
        endpointCompatibility = if ($Port -eq 80) {
            'implicit-http-default-port'
        } else {
            'explicit-port-legacy'
        }
        helperAccount = 'LocalService'
        taskName = $taskName
    }
    Write-Utf8NoBom -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 6)
    Protect-InstallTree -LiteralPath $installRoot
    Set-SecureRuntimeRoot -LiteralPath $runtimeRoot

    $profileDirectory = Split-Path -Parent $profilePath
    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryProfile = Join-Path $profileDirectory "component_profiles.oculink-shim.$operationId.tmp"
    $atomicBackup = Join-Path $profileDirectory "component_profiles.oculink-shim.$operationId.rollback"
    Write-Utf8NoBom -LiteralPath $temporaryProfile -Value ($profiles | ConvertTo-Json -Depth 30)

    $verification = Get-Content -LiteralPath $temporaryProfile -Raw | ConvertFrom-Json
    foreach ($name in @('grd', 'crd')) {
        $entry = @($verification | Where-Object componentName -eq $name)
        if ($entry.Count -ne 1 -or $entry[0].updateCheckerProfiles[0].otaBaseUrl -ne $localBaseUrl) {
            throw "Verification failed for NVIDIA component '$name'."
        }
    }

    [IO.File]::Replace($temporaryProfile, $profilePath, $atomicBackup, $true)
    $profileReplaced = $true
    $patchedProfileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $state.status = 'installed'
    $state.patchedProfileSha256 = $patchedProfileHash
    Write-Utf8NoBom -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 6)
    Protect-InstallTree -LiteralPath $installRoot
    Set-SecureRuntimeRoot -LiteralPath $runtimeRoot
    Remove-Item -LiteralPath $atomicBackup -Force
    $atomicBackup = $null

    Stop-CurrentSessionNvidiaProcesses
} catch {
    $failure = $_
    $restored = -not $profileReplaced
    if ($profileReplaced -and $profileBackup -and (Test-Path -LiteralPath $profileBackup)) {
        try {
            Copy-Item -LiteralPath $profileBackup -Destination $profilePath -Force
            $restored = (
                (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash -eq
                $originalProfileHash
            )
        } catch {
            $restored = $false
        }
    }

    if ($taskRegistered) {
        Stop-ShimTaskAndProcess
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($temporaryProfile) {
        Remove-Item -LiteralPath $temporaryProfile -Force -ErrorAction SilentlyContinue
    }
    if ($atomicBackup) {
        Remove-Item -LiteralPath $atomicBackup -Force -ErrorAction SilentlyContinue
    }

    if ($restored -and $installRootTrusted -and (Test-Path -LiteralPath $installRoot)) {
        if (-not $state) {
            $state = [ordered]@{
                status = 'uninstalled'
                failedAt = (Get-Date).ToString('o')
                profileBackupRelative = $null
                originalProfileSha256 = $null
                patchedProfileSha256 = $null
                localBaseUrl = $null
                verifiedLatestVersion = $null
                helperAccount = 'LocalService'
                taskName = $taskName
            }
        } else {
            $state.status = 'uninstalled'
            $state.uninstalledAt = (Get-Date).ToString('o')
        }
        try {
            Write-Utf8NoBom -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 6)
            Protect-InstallTree -LiteralPath $installRoot
            if (Test-Path -LiteralPath $runtimeRoot) {
                Set-SecureRuntimeRoot -LiteralPath $runtimeRoot
            }
        } catch {
            # Preserve the original failure.
        }
    }

    New-Item -ItemType Directory -Path $runtimeRoot -Force -ErrorAction SilentlyContinue | Out-Null
    try {
        Write-Utf8NoBom -LiteralPath (Join-Path $runtimeRoot 'install-error.log') -Value ($failure | Out-String)
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
