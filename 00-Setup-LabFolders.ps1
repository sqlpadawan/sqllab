[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

# Change to the project directory so all relative paths resolve correctly
Set-Location $PSScriptRoot
Write-Host "Working directory: $PSScriptRoot"

# Resolve config path after $PSScriptRoot is available
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "config.json"
}

if (-not (Test-Path $ConfigPath)) {
    throw "config.json not found at '$ConfigPath'. Verify the file exists in the project root."
}

$config = Get-Content $ConfigPath | ConvertFrom-Json

$folders = @(
    (Split-Path $config.GoldVhdxPath),
    $config.VMStoragePath,
    $config.DiffDiskPath
) | Select-Object -Unique

foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        if ($PSCmdlet.ShouldProcess($folder, "Create directory")) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Write-Host "Created: $folder"
        }
    } else {
        Write-Host "Exists:  $folder"
    }
}

Write-Host "Installing required PowerShell modules..."
if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) {
    Install-Module Microsoft.PowerShell.SecretManagement,
                  Microsoft.PowerShell.SecretStore -Force -Scope AllUsers
}

Write-Host "Enabling Hyper-V role if not present..."
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hv.State -ne 'Enabled') {
    if ($PSCmdlet.ShouldProcess("Hyper-V", "Enable Windows feature")) {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
        Write-Warning "Hyper-V enabled. Reboot required before continuing."
    }
} else {
    Write-Host "Hyper-V already enabled."
}

Write-Host "Creating virtual switches..."

# External switch
$extSwitch = Get-VMSwitch -Name $config.vSwitchExternal -ErrorAction SilentlyContinue
if ($extSwitch) {
    Write-Host "Exists: vSwitch $($config.vSwitchExternal)"
} else {
    # Wait up to 30 seconds for a physical adapter to come Up - Ethernet can
    # take a moment to initialize after a fresh teardown or host boot.
    Write-Host "Waiting for a physical network adapter..."
    $hostNIC = $null
    $nicDeadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $nicDeadline) {
        $hostNIC = (Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
        if ($hostNIC) { break }
        Start-Sleep -Seconds 3
    }
    if (-not $hostNIC) {
        throw "No physical network adapter is Up. Connect an Ethernet cable or ensure Wi-Fi is connected before running setup."
    }
    Write-Host "Using adapter: $hostNIC"
    if ($PSCmdlet.ShouldProcess($config.vSwitchExternal, "Create external vSwitch on $hostNIC")) {
        New-VMSwitch -Name $config.vSwitchExternal -NetAdapterName $hostNIC -AllowManagementOS $true
        Write-Host "Created external vSwitch: $($config.vSwitchExternal)"
    }
}

# Internal switch
$intSwitch = Get-VMSwitch -Name $config.vSwitchInternal -ErrorAction SilentlyContinue
if ($intSwitch) {
    Write-Host "Exists: vSwitch $($config.vSwitchInternal)"
} else {
    if ($PSCmdlet.ShouldProcess($config.vSwitchInternal, "Create internal vSwitch")) {
        New-VMSwitch -Name $config.vSwitchInternal -SwitchType Internal
        Write-Host "Created internal vSwitch: $($config.vSwitchInternal)"
    }
}

# Assign a static IP to the host vNIC on the internal switch so the host can
# reach lab VMs directly via PSRemoting. Without this the vNIC gets only a
# 169.254.x.x link-local address and all WinRM connections time out.
Write-Host "Configuring host IP on internal vSwitch..."
$hostVnic = Get-NetAdapter | Where-Object {
    $_.Name -like "*$($config.vSwitchInternal)*" -and $_.Status -eq 'Up'
}
if (-not $hostVnic) {
    Write-Warning "Could not find a host vNIC for '$($config.vSwitchInternal)'. Assign $($config.HostInternalIP)/24 manually."
} else {
    $existing = Get-NetIPAddress -InterfaceIndex $hostVnic.ifIndex `
                    -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $config.HostInternalIP }
    if ($existing) {
        Write-Host "Exists:  Host vNIC already has $($config.HostInternalIP)"
    } else {
        # Remove any stale link-local or previously assigned addresses first
        Get-NetIPAddress -InterfaceIndex $hostVnic.ifIndex -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        if ($PSCmdlet.ShouldProcess($hostVnic.Name, "Assign $($config.HostInternalIP)/24")) {
            New-NetIPAddress -InterfaceIndex $hostVnic.ifIndex `
                             -IPAddress $config.HostInternalIP `
                             -PrefixLength 24 | Out-Null
            Write-Host "Assigned: $($config.HostInternalIP)/24 on $($hostVnic.Name)"
        }
    }
}

# Add a host route so DC-B subnet traffic (192.168.10.x) goes through the
# internal vSwitch via the DC, not out through the external switch.
# Without this the host uses the wrong interface to reach DC-B VMs.
Write-Host "Configuring host route for DC-B subnet..."
$internalIdx = (Get-NetAdapter | Where-Object { $_.Name -like "*$($config.vSwitchInternal)*" }).ifIndex
if ($internalIdx) {
    New-NetRoute -DestinationPrefix '192.168.10.0/24' `
                 -InterfaceIndex $internalIdx `
                 -NextHop 172.16.10.10 `
                 -ErrorAction SilentlyContinue | Out-Null
    Write-Host "DC-B route added: 192.168.10.0/24 via 172.16.10.10 on internal switch"
}

# Wait for vSwitch NIC bindings to fully initialize before returning.
# On hosts using Wi-Fi adapters for the external switch this can take several
# seconds and Hyper-V will return 000000000000 MACs for new VMs if we proceed
# too quickly.
Write-Host "Waiting for vSwitch initialization..."
Start-Sleep -Seconds 15

Write-Host "`nHost setup complete."