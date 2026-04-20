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

# Create the VM before building unattend.xml so we can read the MAC address
# Hyper-V assigns to the internal NIC. We use it in the first-boot script to
# find the right adapter regardless of how Windows names it.
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

# DC needs a second NIC on the external switch for NAT/internet.
# Add it before reading MACs so both adapters are present.
if ($VMDef.NICs -eq 2) {
    Add-VMNetworkAdapter -VM $vm -SwitchName $Config.vSwitchExternal
    Write-Host "[$($VMDef.Name)] Added external NIC."
}

# Read the MAC Hyper-V assigned to the internal NIC (always index 0).
# Format: Hyper-V gives "AABBCCDDEEFF", PowerShell Get-NetAdapter uses "AA-BB-CC-DD-EE-FF".
$rawMac      = (Get-VMNetworkAdapter -VM $vm)[0].MacAddress
$formattedMac = $rawMac -replace '(..(?!$))', '$1-'
Write-Host "[$($VMDef.Name)] Internal NIC MAC: $formattedMac"

# Build the IP configuration script that will run on first boot.
# It finds the NIC by MAC address so adapter naming doesn't matter.
$gateway    = if ($VMDef.Gateway) { $VMDef.Gateway } else { '' }
$gatewayCmd = if ($VMDef.Gateway) {
    "netsh interface ipv4 add route 0.0.0.0/0 name=`$nicName nexthop=$($VMDef.Gateway) store=persistent"
} else { '' }

$netScript = @"
`$mac    = '$formattedMac'
`$nic    = Get-NetAdapter | Where-Object { `$_.MacAddress -eq `$mac } | Select-Object -First 1
if (-not `$nic) { exit 1 }
`$nicName = `$nic.Name
netsh interface ipv4 set address name="`$nicName" static $($VMDef.IP) 255.255.255.0 $gateway
netsh interface ipv4 set dns    name="`$nicName" static $($VMDef.DNS) primary
$gatewayCmd
# Remove this scheduled task after it has run once
Unregister-ScheduledTask -TaskName 'LabNetConfig' -Confirm:`$false
"@

$netScriptBytes   = [System.Text.Encoding]::Unicode.GetBytes($netScript)
$netScriptEncoded = [Convert]::ToBase64String($netScriptBytes)

# This scheduled task XML runs the IP config script at system startup,
# before any user logs on, with SYSTEM privileges.
# Trigger: AtStartup with a 30-second delay to ensure NICs are ready.
# The script unregisters the task after it runs so it only fires once.
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <BootTrigger>
      <Delay>PT30S</Delay>
      <Enabled>true</Enabled>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NonInteractive -WindowStyle Hidden -EncodedCommand $netScriptEncoded</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$localAdminPass = Get-Secret -Name 'LocalAdminPass' -Vault $Config.SecretsVault -AsPlainText

Write-Host "[$($VMDef.Name)] Injecting unattend.xml and first-boot network task..."

$mountedVhd  = Mount-VHD $diffVhdx -PassThru | Get-Disk | Get-Partition |
    Where-Object { $_.Type -eq 'Basic' } | Get-Volume
$driveLetter = $mountedVhd.DriveLetter

# Inject the unattend.xml - kept minimal: hostname, timezone, and password only.
# Networking is handled entirely by the scheduled task above to avoid the
# unreliable Identifier-based TCPIP component in Windows Server 2025.
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

$unattendPath = "${driveLetter}:\Windows\Panther\unattend.xml"
New-Item -Path (Split-Path $unattendPath) -ItemType Directory -Force | Out-Null
$unattendXml | Out-File -FilePath $unattendPath -Encoding utf8

# Drop the scheduled task XML into the offline VHDX so it is registered
# before the OS ever boots. Task Scheduler picks up XML files placed in
# %SystemRoot%\System32\Tasks automatically on first boot.
$taskDir  = "${driveLetter}:\Windows\System32\Tasks"
New-Item -Path $taskDir -ItemType Directory -Force | Out-Null
$taskXml | Out-File -FilePath "$taskDir\LabNetConfig" -Encoding unicode

Dismount-VHD $diffVhdx

Start-VM -VM $vm
Write-Host "[$($VMDef.Name)] VM started. Waiting for WinRM on $($VMDef.IP)..."

# Allow extra time for first boot (sysprep + scheduled task 30s delay)
$deadline = (Get-Date).AddMinutes(20)
while ((Get-Date) -lt $deadline) {
    if (Test-WSMan -ComputerName $VMDef.IP -ErrorAction SilentlyContinue) {
        Write-Host "[$($VMDef.Name)] WinRM is up."
        break
    }
    Start-Sleep -Seconds 15
}
