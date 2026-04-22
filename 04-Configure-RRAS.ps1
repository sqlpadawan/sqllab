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

# Derive the static MACs using the same formula as 02-New-LabVM.ps1.
# Internal NIC: 00-15-5D + octets 2-3-4 of the DC IP
# External NIC: same but last byte incremented by 1
# This is more reliable than querying Get-VMNetworkAdapter which can return
# duplicate MACs when the switch binding hasn't fully initialized.
$ipOctets = $VMDef.IP -split '\.'
$intSuffix = '{0:X2}{1:X2}{2:X2}' -f [int]$ipOctets[1], [int]$ipOctets[2], [int]$ipOctets[3]
$extSuffix = '{0:X2}{1:X2}{2:X2}' -f [int]$ipOctets[1], [int]$ipOctets[2], ([int]$ipOctets[3] + 1)
$intMac = ("00155D$intSuffix") -replace '(..(?!$))', '$1-'
$extMac = ("00155D$extSuffix") -replace '(..(?!$))', '$1-'

Write-Host "[$($VMDef.Name)] Internal MAC: $intMac  External MAC: $extMac"

Invoke-Command -ComputerName $VMDef.IP -Credential $cred -ScriptBlock {
    param($IntMac, $ExtMac)

    Write-Host "Installing RRAS and Routing..."
    Install-WindowsFeature RemoteAccess, Routing, RSAT-RemoteAccess-PowerShell `
        -IncludeManagementTools

    Write-Host "Starting RRAS service..."
    Install-RemoteAccess -VpnType RoutingOnly

    Write-Host "Identifying NICs by IP address..."
    # Find internal NIC - the one with the 172.16.x.x lab IP
    $int = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } |
        Where-Object {
            (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue).IPAddress -like '172.16.*'
        } | Select-Object -First 1

    # Find external NIC - the one that is NOT the internal NIC
    $ext = Get-NetAdapter -Physical | Where-Object {
        $_.Status -eq 'Up' -and $_.Name -ne $int.Name
    } | Select-Object -First 1

    if (-not $int) { throw "Internal NIC (172.16.x.x) not found." }
    if (-not $ext) { throw "External NIC not found." }

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

    # Add 192.168.10.1 to the internal NIC so DC-B VMs (192.168.10.x) have a
    # reachable gateway on their own subnet. Without this they cannot route
    # through the DC even though RRAS is running.
    $existing = Get-NetIPAddress -InterfaceAlias $int.Name -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '192.168.10.1' }
    if (-not $existing) {
        New-NetIPAddress -InterfaceAlias $int.Name `
                         -IPAddress 192.168.10.1 `
                         -PrefixLength 24 | Out-Null
        Write-Host "Added 192.168.10.1/24 to $($int.Name) for DC-B routing."
    }

    Write-Host "RRAS configuration complete."

    # Ensure the external NIC has a DHCP address. Removing IPs from it
    # can cause it to fall back to link-local, breaking internet access.
    Write-Host "Verifying external NIC has internet connectivity..."
    $extIP = (Get-NetIPAddress -InterfaceAlias $ext.Name -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' }).IPAddress
    if (-not $extIP) {
        Write-Host "External NIC has no routable IP - renewing DHCP..."
        Set-NetIPInterface -InterfaceAlias $ext.Name -Dhcp Enabled -ErrorAction SilentlyContinue
        ipconfig /release $ext.Name | Out-Null
        Start-Sleep -Seconds 3
        ipconfig /renew $ext.Name | Out-Null
        Start-Sleep -Seconds 5
        Write-Host "DHCP renewed on $($ext.Name)."
    }

} -ArgumentList $intMac, $extMac
