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

# Create the VM now (before injecting unattend.xml) so we can read the MAC
# address that Hyper-V assigns to the internal NIC. We use that MAC in the
# specialize-pass netsh script to find the right adapter regardless of how
# Windows names it (Ethernet, Ethernet 2, etc.).
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
       -AutomaticCheckpointsEnabled $false

Set-VMFirmware -VM $vm -EnableSecureBoot Off

# The DC needs a second NIC on the external switch for internet/NAT.
# Add it before reading MACs so both adapters are present when we snapshot them.
if ($VMDef.NICs -eq 2) {
    Add-VMNetworkAdapter -VM $vm -SwitchName $Config.vSwitchExternal
    Write-Host "[$($VMDef.Name)] Added external NIC."
}

# Read the MAC address of the internal NIC (always the first adapter).
# Hyper-V formats it as "AABBCCDDEEFF" - netsh expects "AA-BB-CC-DD-EE-FF".
$internalMac = (Get-VMNetworkAdapter -VM $vm)[0].MacAddress -replace '(..)', '$1-' -replace '-$', ''
Write-Host "[$($VMDef.Name)] Internal NIC MAC: $internalMac"

# Build the gateway line conditionally - the DC has no gateway.
$gatewayCmd = if ($VMDef.Gateway) {
    "netsh interface ipv4 add route 0.0.0.0/0 name=`"%NIC%`" nexthop=$($VMDef.Gateway) store=persistent"
} else { "" }

# This PowerShell script runs inside the VM during the specialize pass.
# It finds the NIC by MAC address and applies the static IP, gateway, and DNS.
# Using RunSynchronousCommand avoids the Identifier-matching bug in the
# Microsoft-Windows-TCPIP component, which silently fails on Server 2025 when
# the adapter name doesn't match "Local Area Connection".
$netConfigScript = @"
`$mac = '$internalMac'
`$nic = Get-NetAdapter | Where-Object { `$_.MacAddress -eq `$mac }
if (-not `$nic) { exit 1 }
`$name = `$nic.Name
netsh interface ipv4 set address name="`$name" static $($VMDef.IP) 255.255.255.0 $(if ($VMDef.Gateway) { $VMDef.Gateway } else { '' })
netsh interface ipv4 set dns name="`$name" static $($VMDef.DNS) primary
$(if ($VMDef.Gateway) { "netsh interface ipv4 add route 0.0.0.0/0 name=`"`$name`" nexthop=$($VMDef.Gateway) store=persistent" })
"@

# Encode the script as Base64 so it survives the XML embedding cleanly.
$scriptBytes   = [System.Text.Encoding]::Unicode.GetBytes($netConfigScript)
$encodedScript = [Convert]::ToBase64String($scriptBytes)

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
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Configure static IP via MAC address</Description>
          <Path>powershell.exe -NonInteractive -EncodedCommand $encodedScript</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
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
          <Value>$(Get-Secret -Name 'LocalAdminPass' -Vault $Config.SecretsVault -AsPlainText)</Value>
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
          <Value>$(Get-Secret -Name 'LocalAdminPass' -Vault $Config.SecretsVault -AsPlainText)</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@

# Mount the VHDX and inject unattend.xml before first boot.
$mountedVhd  = Mount-VHD $diffVhdx -PassThru | Get-Disk | Get-Partition |
    Where-Object { $_.Type -eq 'Basic' } | Get-Volume
$driveLetter  = $mountedVhd.DriveLetter
$unattendPath = "${driveLetter}:\Windows\Panther\unattend.xml"
New-Item -Path (Split-Path $unattendPath) -ItemType Directory -Force | Out-Null
$unattendXml | Out-File -FilePath $unattendPath -Encoding utf8
Dismount-VHD $diffVhdx

Start-VM -VM $vm
Write-Host "[$($VMDef.Name)] VM started. Waiting for WinRM on $($VMDef.IP)..."

$deadline = (Get-Date).AddMinutes(15)
while ((Get-Date) -lt $deadline) {
    if (Test-WSMan -ComputerName $VMDef.IP -ErrorAction SilentlyContinue) {
        Write-Host "[$($VMDef.Name)] WinRM is up."
        break
    }
    Start-Sleep -Seconds 15
}
