[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

$goldVhdx   = $Config.GoldVhdxPath
$diffVhdx   = Join-Path $Config.DiffDiskPath "$($VMDef.Name).vhdx"
$vmPath     = Join-Path $Config.VMStoragePath $VMDef.Name
$diskSizeGB = if ($VMDef.DiskSizeGB) { $VMDef.DiskSizeGB } else { 64 }

if (Get-VM -Name $VMDef.Name -ErrorAction SilentlyContinue) {
    Write-Warning "VM $($VMDef.Name) already exists. Skipping."
    return
}

# Abort if an orphaned differencing disk already exists - do not overwrite it.
# Run Remove-Lab.ps1 or manually delete the file before retrying.
if (Test-Path $diffVhdx) {
    Write-Error "[$($VMDef.Name)] Orphaned differencing disk found: $diffVhdx`nDelete it before retrying: Remove-Item '$diffVhdx' -Force"
    return
}

Write-Host "[$($VMDef.Name)] Creating differencing disk ($diskSizeGB GB) from $goldVhdx"
if ($PSCmdlet.ShouldProcess($diffVhdx, "Create differencing VHDX")) {
    try {
        New-VHD -Path $diffVhdx -ParentPath $goldVhdx -Differencing -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "[$($VMDef.Name)] New-VHD failed: $_"
        return
    }
    Resize-VHD -Path $diffVhdx -SizeBytes ($diskSizeGB * 1GB)
    Write-Host "[$($VMDef.Name)] Disk resized to $diskSizeGB GB."
}

# Create the VM before injecting unattend.xml so we can read the MAC address
# Hyper-V assigns to the internal NIC.
Write-Host "[$($VMDef.Name)] Creating VM..."
if (-not $PSCmdlet.ShouldProcess($VMDef.Name, "New-VM")) { return }

try {
    $vm = New-VM -Name $VMDef.Name `
                 -Path $vmPath `
                 -Generation 2 `
                 -MemoryStartupBytes ($VMDef.MemoryGB * 1GB) `
                 -VHDPath $diffVhdx `
                 -SwitchName $Config.vSwitchInternal `
                 -ErrorAction Stop
} catch {
    Write-Error "[$($VMDef.Name)] New-VM failed: $_`nVerify that vSwitch '$($Config.vSwitchInternal)' exists. Run .\00-Setup-LabFolders.ps1 if needed."
    return
}

Set-VM -VM $vm -ProcessorCount $VMDef.VCPU `
       -DynamicMemory:$false `
       -AutomaticCheckpointsEnabled $false `
       -AutomaticStopAction ShutDown `
       -AutomaticStartAction StartIfRunning

Set-VMFirmware -VM $vm -EnableSecureBoot Off

# DC needs a second NIC on the external switch for NAT/internet.
if ($VMDef.NICs -eq 2) {
    Add-VMNetworkAdapter -VM $vm -SwitchName $Config.vSwitchExternal
    Write-Host "[$($VMDef.Name)] Added external NIC."
}

# Generate static MACs from the Hyper-V host MAC pool and assign them explicitly.
# Dynamic MAC assignment can fail on some hosts (returns 000000000000 indefinitely).
# Internal NIC uses IP octets 2-3-4 as suffix; external NIC (DC only) increments last byte.
$ipOctets  = $VMDef.IP -split '\.'
$macSuffix = '{0:X2}{1:X2}{2:X2}' -f [int]$ipOctets[1], [int]$ipOctets[2], [int]$ipOctets[3]
$staticMac = "00155D$macSuffix"
Write-Host "[$($VMDef.Name)] Assigning static MAC: $staticMac"
Set-VMNetworkAdapter -VMNetworkAdapterId (Get-VMNetworkAdapter -VM $vm)[0].Id -StaticMacAddress $staticMac
$rawMac       = $staticMac
$formattedMac = $rawMac -replace '(..(?!$))', '$1-'
Write-Host "[$($VMDef.Name)] Internal NIC MAC: $formattedMac"

# Assign a distinct MAC to the external NIC if present (DC only)
if ($VMDef.NICs -eq 2) {
    $extSuffix  = '{0:X2}{1:X2}{2:X2}' -f [int]$ipOctets[1], [int]$ipOctets[2], ([int]$ipOctets[3] + 1)
    $extStaticMac = "00155D$extSuffix"
    Set-VMNetworkAdapter -VMNetworkAdapterId (Get-VMNetworkAdapter -VM $vm)[1].Id -StaticMacAddress $extStaticMac
    Write-Host "[$($VMDef.Name)] External NIC MAC: $($extStaticMac -replace '(..(?!$))', '$1-')"
}

$localAdminPass = Get-Secret -Name 'LocalAdminPass' -Vault $Config.SecretsVault -AsPlainText

# Minimal unattend.xml - hostname, timezone, and password only.
# Networking is applied via PowerShell Direct after first boot (below),
# which is reliable regardless of how Windows names the adapters.
Write-Host "[$($VMDef.Name)] Injecting unattend.xml..."
$unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>$($VMDef.Name)</ComputerName>
      <TimeZone>$($Config.TimeZone)</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>3</LogonCount>
        <Username>Administrator</Username>
        <Password>
          <Value>$localAdminPass</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$localAdminPass</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@

# Mount the VHDX and find the Windows partition by looking for Windows\System32.
# Using label or size is fragile; checking for the Windows folder is definitive.
$mountedDisk = Mount-VHD $diffVhdx -PassThru | Get-Disk
$driveLetter = $null
foreach ($part in ($mountedDisk | Get-Partition | Where-Object { $_.DriveLetter -ne [char]0 })) {
    if (Test-Path "$($part.DriveLetter):\Windows\System32") {
        $driveLetter = $part.DriveLetter
        break
    }
}
if (-not $driveLetter) {
    Dismount-VHD $diffVhdx
    Write-Error "[$($VMDef.Name)] Could not find Windows partition in $diffVhdx"
    return
}
Write-Host "[$($VMDef.Name)] Windows partition: ${driveLetter}:"
$unattendPath = "${driveLetter}:\Windows\Panther\unattend.xml"
New-Item -Path (Split-Path $unattendPath) -ItemType Directory -Force | Out-Null
[System.IO.File]::WriteAllText($unattendPath, $unattendXml, [System.Text.UTF8Encoding]::new($false))
Write-Host "[$($VMDef.Name)] unattend.xml written to $unattendPath"
Dismount-VHD $diffVhdx

Start-VM -VM $vm
Write-Host "[$($VMDef.Name)] VM started. Waiting for first boot via PowerShell Direct..."

# PowerShell Direct connects over the Hyper-V bus - no network needed.
# Poll until the VM accepts credentials, which means OOBE is complete.
$localCred = New-Object PSCredential("Administrator",
    (Get-Secret -Name 'LocalAdminPass' -Vault $Config.SecretsVault))

$deadline = (Get-Date).AddMinutes(20)
$booted   = $false
while ((Get-Date) -lt $deadline) {
    try {
        Invoke-Command -VMName $VMDef.Name -Credential $localCred `
            -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop | Out-Null
        $booted = $true
        break
    } catch {
        Start-Sleep -Seconds 15
    }
}

if (-not $booted) {
    Write-Error "[$($VMDef.Name)] VM did not become available via PowerShell Direct within 20 minutes."
    return
}

Write-Host "[$($VMDef.Name)] VM is up. Configuring network via PowerShell Direct..."

# Apply static IP, gateway, and DNS via PowerShell Direct.
# Find the internal NIC by looking for a link-local 169.254.x.x address -
# this is always the unconfigured internal NIC regardless of MAC format or
# adapter naming. No MAC matching needed.
$vmIP      = $VMDef.IP
$vmPrefix  = $VMDef.PrefixLen
$vmGateway = $VMDef.Gateway
$vmDNS     = $VMDef.DNS

Invoke-Command -VMName $VMDef.Name -Credential $localCred -ScriptBlock {
    param($IP, $Prefix, $Gateway, $DNS, $Role)

    # Find the NIC with a link-local address - that is always the unconfigured
    # internal NIC. This avoids all MAC format matching issues entirely.
    $nic = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } |
        Where-Object {
            (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue).IPAddress -like '169.254.*'
        } | Select-Object -First 1

    if (-not $nic) {
        # Fallback: just take the first physical Up adapter
        $nic = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } |
            Select-Object -First 1
    }

    if (-not $nic) {
        Write-Warning "No suitable NIC found. Adapter list:"
        Get-NetAdapter | Select-Object Name, Status, MacAddress
        return
    }

    Write-Host "Configuring NIC: $($nic.Name)"

    # Remove any existing non-wellknown IP before assigning static
    Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceIndex $nic.ifIndex `
                     -IPAddress $IP -PrefixLength $Prefix | Out-Null

    if ($Gateway) {
        New-NetRoute -InterfaceIndex $nic.ifIndex `
                     -DestinationPrefix '0.0.0.0/0' `
                     -NextHop $Gateway -ErrorAction SilentlyContinue | Out-Null
    }

    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DNS

    Write-Host "Network configured: $IP/$Prefix  GW=$Gateway  DNS=$DNS"

    # Open WinRM firewall to Any so the host can reach this VM regardless of
    # which subnet it is on. Default is LocalSubnet which blocks cross-subnet
    # connections from the Hyper-V host.
    Set-NetFirewallRule -DisplayName "Windows Remote Management (HTTP-In)" `
        -RemoteAddress Any -ErrorAction SilentlyContinue

    # Enable File and Printer Sharing so the host can map the admin share (C$)
    # for copying the SQL Server ISO to the VM during stage 6.
    Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing" -ErrorAction SilentlyContinue

    # Disable Azure Arc setup on all VMs. Windows Server 2025 runs an Arc
    # onboarding task on first boot - disable it via registry before it fires.
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\AzureArc' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\AzureArc' `
        -Name 'ArcSetupDisabled' -Value 1 -Type DWord
    # Also disable the scheduled task directly as a belt-and-suspenders measure
    Disable-ScheduledTask -TaskPath '\Microsoft\Azure Arc' -TaskName 'Azure Arc Setup' `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Azure Arc setup disabled."

    # Disable IE Enhanced Security Configuration on the workstation only.
    # IE ESC is left enabled on domain controllers and SQL servers since those
    # roles should not be used for general web browsing.
    if ($Role -eq 'Workstation') {
        $ieEscAdminKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
        $ieEscUserKey  = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'
        Set-ItemProperty -Path $ieEscAdminKey -Name 'IsInstalled' -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $ieEscUserKey  -Name 'IsInstalled' -Value 0 -ErrorAction SilentlyContinue
        Write-Host "IE Enhanced Security Configuration disabled."
    }

    # Register a startup task to reapply the IP on reboot until a role makes
    # it permanent. Uses the same 169.254 detection approach.
    $taskScript = @"
`$nic = Get-NetAdapter -Physical | Where-Object { `$_.Status -eq 'Up' } |
    Where-Object {
        (Get-NetIPAddress -InterfaceIndex `$_.ifIndex -AddressFamily IPv4 ``
            -ErrorAction SilentlyContinue).IPAddress -like '169.254.*'
    } | Select-Object -First 1
if (-not `$nic) { exit 0 }
`$existing = Get-NetIPAddress -InterfaceIndex `$nic.ifIndex -AddressFamily IPv4 ``
    -ErrorAction SilentlyContinue | Where-Object { `$_.IPAddress -eq '$IP' }
if (-not `$existing) {
    Get-NetIPAddress -InterfaceIndex `$nic.ifIndex -AddressFamily IPv4 ``
        -ErrorAction SilentlyContinue |
        Where-Object { `$_.PrefixOrigin -ne 'WellKnown' } |
        Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex `$nic.ifIndex -IPAddress '$IP' -PrefixLength $Prefix -ErrorAction SilentlyContinue
    $(if ($Gateway) { "New-NetRoute -InterfaceIndex `$nic.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop '$Gateway' -ErrorAction SilentlyContinue" })
    Set-DnsClientServerAddress -InterfaceIndex `$nic.ifIndex -ServerAddresses '$DNS'
}
"@
    $encoded   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($taskScript))
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'LabNetConfig' -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Startup task registered."

} -ArgumentList $vmIP, $vmPrefix, $vmGateway, $vmDNS, $VMDef.Role

# Only poll WinRM for VMs the host can reach directly (172.16.10.x subnet).
# VMs on 192.168.10.x route through RRAS which isn't configured until stage 4,
# so skip the wait for those - they will be reachable after stage 4 completes.
if ($VMDef.IP -like '172.16.*') {
    Write-Host "[$($VMDef.Name)] Waiting for WinRM on $($VMDef.IP)..."
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-WSMan -ComputerName $VMDef.IP -ErrorAction SilentlyContinue) {
            Write-Host "[$($VMDef.Name)] WinRM is up."
            break
        }
        Start-Sleep -Seconds 15
    }
} else {
    Write-Host "[$($VMDef.Name)] Skipping WinRM check - $($VMDef.IP) requires RRAS routing (configured in stage 4)."
}
