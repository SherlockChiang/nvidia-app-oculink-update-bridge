Set-StrictMode -Version 2

function Get-PresentNvidiaDeviceIds {
    $instanceIds = @()
    try {
        $instanceIds = @(
            Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
                Select-Object -ExpandProperty InstanceId
        )
    } catch {
        $pnputilOutput = & pnputil.exe /enum-devices /class Display /connected
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to enumerate connected display adapters.'
        }
        $instanceIds = @(
            [regex]::Matches(
                ($pnputilOutput -join "`n"),
                'PCI\\VEN_10DE&DEV_[A-Fa-f0-9]{4}&SUBSYS_[A-Fa-f0-9]{8}[^\r\n]*'
            ) | ForEach-Object { $_.Value }
        )
    }

    $deviceIds = foreach ($instanceId in $instanceIds) {
        if (
            [string]$instanceId -match
            'PCI\\VEN_10DE&DEV_([A-Fa-f0-9]{4})&SUBSYS_([A-Fa-f0-9]{4})([A-Fa-f0-9]{4})'
        ) {
            (
                $Matches[1] + '_10DE_' +
                $Matches[2] + '_' +
                $Matches[3] + '_1'
            ).ToUpperInvariant()
        }
    }
    $deviceIds = @($deviceIds | Sort-Object -Unique)
    if ($deviceIds.Count -lt 1) {
        throw 'No connected NVIDIA display adapter with a PCI subsystem ID was found.'
    }
    return $deviceIds
}

Export-ModuleMember -Function Get-PresentNvidiaDeviceIds

