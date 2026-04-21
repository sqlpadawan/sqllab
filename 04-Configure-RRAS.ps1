[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$cred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

# Read the MACs from Hyper-V on the host so NIC identification inside the VM
# is reliable regardless of adapter naming or IP state at the time of the call.
$adapters    = Get-VMNetworkAdapter -VMName $VMDef.Name
$intMac      = ($adapters | Where-Object { $_.SwitchName -eq $Config.vSwitchInternal } |
                Select-Object -First 1).MacAddress -replace '(..(?!$))', '$1-'
$extMac      = ($adapters | Where-Object { $_.SwitchName -eq $Config.vSwitchExternal } |
                Select-Object -First 1).MacAddress -replace '(..(?!$))', '$1-'

Write-Host "[$($VMDef.Name)] Internal MAC: $intMac  External MAC: $extMac"

Invoke-Command -ComputerName $VMDef.IP -Credential $cred -ScriptBlock {
    param($IntMac, $ExtMac)

    Write-Host "Installing RRAS and Routing..."
    Install-WindowsFeature RemoteAccess, Routing, RSAT-RemoteAccess-PowerShell `
        -IncludeManagementTools

    Write-Host "Starting RRAS service..."
    Install-RemoteAccess -VpnType RoutingOnly

    Write-Host "Identifying NICs by MAC address..."
    $int = Get-NetAdapter | Where-Object { $_.MacAddress -eq $IntMac } | Select-Object -First 1
    $ext = Get-NetAdapter | Where-Object { $_.MacAddress -eq $ExtMac } | Select-Object -First 1

    if (-not $int) { throw "Internal NIC with MAC $IntMac not found." }
    if (-not $ext) { throw "External NIC with MAC $ExtMac not found." }

    Write-Host "External NIC: $($ext.Name)  Internal NIC: $($int.Name)"

    Write-Host "Configuring NAT..."
    netsh routing ip nat install
    netsh routing ip nat add interface name="$($ext.Name)" mode=full
    netsh routing ip nat add interface name="$($int.Name)" mode=private

    Write-Host "Enabling IP forwarding..."
    Set-NetIPInterface -InterfaceAlias $ext.Name -Forwarding Enabled
    Set-NetIPInterface -InterfaceAlias $int.Name -Forwarding Enabled

    Write-Host "Adding static routes for lab subnets..."
    New-NetRoute -DestinationPrefix "172.16.10.0/24" `
        -InterfaceAlias $int.Name -RouteMetric 10 -ErrorAction SilentlyContinue
    New-NetRoute -DestinationPrefix "192.168.10.0/24" `
        -InterfaceAlias $int.Name -RouteMetric 10 -ErrorAction SilentlyContinue

    Write-Host "RRAS configuration complete."

} -ArgumentList $intMac, $extMac
