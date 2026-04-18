[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

$goldVhdx   = if ($VMDef.OS -eq 'Win11') { $Config.Win11VhdxPath } else { $Config.GoldVhdxPath }
$diffVhdx   = Join-Path $Config.DiffDiskPath "$($VMDef.Name).vhdx"
$vmPath     = Join-Path $Config.VMStoragePath $VMDef.Name
$diskSizeGB = if ($VMDef.DiskSizeGB) { $VMDef.DiskSizeGB } else { 60 }

if (Get-VM -Name $VMDef.Name -ErrorAction SilentlyContinue) {
    Write-Warning "VM $($VMDef.Name) already exists. Skipping."
    return
}

Write-Host "[$($VMDef.Name)] Creating differencing disk ($diskSizeGB GB) from $goldVhdx"
if ($PSCmdlet.ShouldProcess($diffVhdx, "Create differencing VHDX")) {
    New-VHD -Path $diffVhdx -ParentPath $goldVhdx -Differencing | Out-Null

    if ($VMDef.DiskSizeGB) {
        Resize-VHD -Path $diffVhdx -SizeBytes ($diskSizeGB * 1GB)
        Write-Host "[$($VMDef.Name)] Disk resized to $diskSizeGB GB."
    }
}

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
    <component name="Microsoft-Windows-TCPIP"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>Local Area Connection</Identifier>
          <Ipv4Settings><DhcpEnabled>false</DhcpEnabled></Ipv4Settings>
          <UnicastIpAddresses>
            <IpAddress wcm:action="add" wcm:keyValue="1">
              $($VMDef.IP)/$($VMDef.PrefixLen)
            </IpAddress>
          </UnicastIpAddresses>
          $(if ($VMDef.Gateway) {
            "<Routes><Route wcm:action=`"add`"><Identifier>0</Identifier>" +
            "<Metric>256</Metric><NextHopAddress>$($VMDef.Gateway)</NextHopAddress>" +
            "<Prefix>0.0.0.0/0</Prefix></Route></Routes>"
          })
        </Interface>
      </Interfaces>
    </component>
    <component name="Microsoft-Windows-DNS-Client"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>Local Area Connection</Identifier>
          <DNSServerSearchOrder>
            <IpAddress wcm:action="add" wcm:keyValue="1">$($VMDef.DNS)</IpAddress>
          </DNSServerSearchOrder>
        </Interface>
      </Interfaces>
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

$mountedVhd  = Mount-VHD $diffVhdx -PassThru | Get-Disk | Get-Partition |
    Where-Object { $_.Type -eq 'Basic' } | Get-Volume
$driveLetter = $mountedVhd.DriveLetter
$unattendPath = "${driveLetter}:\Windows\Panther\unattend.xml"
New-Item -Path (Split-Path $unattendPath) -ItemType Directory -Force | Out-Null
$unattendXml | Out-File -FilePath $unattendPath -Encoding utf8
Dismount-VHD $diffVhdx

Write-Host "[$($VMDef.Name)] Creating VM..."
if ($PSCmdlet.ShouldProcess($VMDef.Name, "New-VM")) {
    $vm = New-VM -Name $VMDef.Name `
                 -Path $vmPath `
                 -Generation 2 `
                 -MemoryStartupBytes ($VMDef.MemoryGB * 1GB) `
                 -VHDPath $diffVhdx `
                 -SwitchName $Config.vSwitchInternal

    Set-VM -VM $vm -ProcessorCount $VMDef.VCPU `
           -DynamicMemory:$false `
           -AutomaticCheckpointsEnabled $false

    Set-VMFirmware -VM $vm -EnableSecureBoot Off

    if ($VMDef.NICs -eq 2) {
        Add-VMNetworkAdapter -VM $vm -SwitchName $Config.vSwitchExternal
        Write-Host "[$($VMDef.Name)] Added external NIC."
    }

    Start-VM -VM $vm
    Write-Host "[$($VMDef.Name)] VM started. Waiting for WinRM..."

    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        if (Test-WSMan -ComputerName $VMDef.IP -ErrorAction SilentlyContinue) {
            Write-Host "[$($VMDef.Name)] WinRM is up."
            break
        }
        Start-Sleep -Seconds 15
    }
}
