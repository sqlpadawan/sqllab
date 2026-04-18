[CmdletBinding()]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

$cred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

Invoke-Command -ComputerName $VMDef.IP -Credential $cred -ScriptBlock {
    param($ExtNIC, $IntNIC)

    Write-Host "Installing RRAS and Routing..."
    Install-WindowsFeature RemoteAccess, Routing, RSAT-RemoteAccess-PowerShell `
        -IncludeManagementTools

    Write-Host "Starting RRAS service..."
    Install-RemoteAccess -VpnType RoutingOnly

    Write-Host "Identifying NICs..."
    $ext = Get-NetAdapter | Where-Object {
        (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue).IPAddress -notlike '172.16.*'
    } | Select-Object -First 1

    $int = Get-NetAdapter | Where-Object {
        (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue).IPAddress -like '172.16.*'
    } | Select-Object -First 1

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

} -ArgumentList $Config.DCExternalNIC, $Config.DCInternalNIC
