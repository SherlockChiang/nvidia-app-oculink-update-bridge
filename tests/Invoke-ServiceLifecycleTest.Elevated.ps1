[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw 'This lifecycle test must run from an elevated PowerShell process.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$serviceName = 'NvidiaAppOculinkShimV4Test'
$testRoot = 'C:\ProgramData\NvidiaAppOculinkShimV4Test'
$runtimeRoot = Join-Path $testRoot 'runtime'
$sourceExe =
    Join-Path $repositoryRoot 'artifacts\publish\win-x64\NvidiaAppOculinkShim.exe'
$targetExe = Join-Path $testRoot 'NvidiaAppOculinkShim.exe'
$configPath = Join-Path $testRoot 'config.json'
$resultPath = Join-Path $repositoryRoot 'artifacts\service-lifecycle.json'
$token = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()

function Remove-TestService {
    if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
        return
    }
    $serviceRecord =
        Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    if ([string]$serviceRecord.PathName -notlike "*$targetExe*") {
        throw "Refusing to remove an unexpected service: $($serviceRecord.PathName)"
    }
    & sc.exe stop $serviceName | Out-Null
    foreach ($attempt in 1..40) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service -or $service.Status -eq 'Stopped') {
            break
        }
        Start-Sleep -Milliseconds 250
    }
    & sc.exe delete $serviceName | Out-Null
}

function Remove-TestRoot {
    if (-not (Test-Path -LiteralPath $testRoot)) {
        return
    }
    $resolved = (Resolve-Path -LiteralPath $testRoot).Path
    if ($resolved -ne $testRoot) {
        throw "Refusing cleanup of unexpected path: $resolved"
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

function Set-TestAcls {
    $administrators =
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $localService = [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
    $inheritance =
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $rootAcl = [Security.AccessControl.DirectorySecurity]::new()
    $rootAcl.SetAccessRuleProtection($true, $false)
    $rootAcl.SetOwner($administrators)
    foreach ($sid in @($administrators, $system)) {
        $rootAcl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $none,
                $allow
            )
        )
    }
    $rootAcl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $localService,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            $none,
            $allow
        )
    )
    Set-Acl -LiteralPath $testRoot -AclObject $rootAcl

    $runtimeAcl = [Security.AccessControl.DirectorySecurity]::new()
    $runtimeAcl.SetAccessRuleProtection($true, $false)
    $runtimeAcl.SetOwner($administrators)
    foreach ($sid in @($administrators, $system)) {
        $runtimeAcl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $none,
                $allow
            )
        )
    }
    $runtimeAcl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $localService,
            [Security.AccessControl.FileSystemRights]::Modify,
            $inheritance,
            $none,
            $allow
        )
    )
    Set-Acl -LiteralPath $runtimeRoot -AclObject $runtimeAcl
}

Remove-TestService
Remove-TestRoot
try {
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourceExe -Destination $targetExe
    $config = [ordered]@{
        port = $port
        token = $token
        runtimeDirectory = $runtimeRoot
    }
    [IO.File]::WriteAllText(
        $configPath,
        ($config | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
    Set-TestAcls

    $binaryPath =
        '"' + $targetExe + '" --service --service-name "' +
        $serviceName + '" --config "' + $configPath + '"'
    & sc.exe create $serviceName `
        binPath= $binaryPath `
        start= demand `
        obj= 'NT AUTHORITY\LocalService' `
        DisplayName= 'NVIDIA App OCuLink Shim v4 Test' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'sc.exe create failed.'
    }
    & sc.exe failure $serviceName `
        reset= 86400 `
        actions= 'restart/5000/restart/15000/restart/60000' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'sc.exe failure configuration failed.'
    }
    & sc.exe failureflag $serviceName 1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'sc.exe failureflag configuration failed.'
    }
    & sc.exe start $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'sc.exe start failed.'
    }

    $health = $null
    foreach ($attempt in 1..40) {
        try {
            $health = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$port/$token/health" `
                -TimeoutSec 2
            if ($health.status -eq 'ok') {
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if ($health.status -ne 'ok' -or [int]$health.version -ne 4) {
        throw 'The SCM-hosted v4 helper did not become healthy.'
    }

    $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($health.pid)"
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
    $result = [ordered]@{
        health = $health.status
        serviceName = $serviceName
        proxyVersion = [int]$health.version
        serviceState = [string]$service.State
        startName = [string]$service.StartName
        processSid = [string]$owner.Sid
        runtimeLogExists =
            Test-Path -LiteralPath (Join-Path $runtimeRoot 'shim.log')
    }
    if (
        $result.serviceState -ne 'Running' -or
        $result.processSid -ne 'S-1-5-19' -or
        -not $result.runtimeLogExists
    ) {
        throw 'The SCM service identity or runtime ACL verification failed.'
    }

    Stop-Process -Id ([int]$health.pid) -Force
    $recoveredHealth = $null
    foreach ($attempt in 1..120) {
        try {
            $candidate = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$port/$token/health" `
                -TimeoutSec 2
            if (
                $candidate.status -eq 'ok' -and
                [int]$candidate.pid -ne [int]$health.pid
            ) {
                $recoveredHealth = $candidate
                break
            }
        } catch {
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $recoveredHealth) {
        throw 'SCM did not recover the isolated test service within 30 seconds.'
    }
    $result['recovered'] = $true
    $result['previousPid'] = [int]$health.pid
    $result['recoveredPid'] = [int]$recoveredHealth.pid
    $result['recoveredServiceState'] =
        [string](Get-Service -Name $serviceName).Status
    New-Item -ItemType Directory -Path (Split-Path -Parent $resultPath) -Force |
        Out-Null
    [IO.File]::WriteAllText(
        $resultPath,
        ($result | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
} finally {
    Remove-TestService
    Remove-TestRoot
}
