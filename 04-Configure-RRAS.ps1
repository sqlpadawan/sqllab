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

Invoke-Command -ComputerName $VMDef.IP -Credential $cred -ScriptBlock {

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

    # Suppress the external NIC from registering in AD DNS. Without this,
    # the DC's home-network DHCP IP gets added as an A record in sqllab.local,
    # which pollutes DNS and can cause Kerberos issues.
    Write-Host "Suppressing external NIC DNS registration..."
    Set-DnsClient -InterfaceAlias $ext.Name -RegisterThisConnectionsAddress $false

    # Enable OS-level IP routing. This registry key is required for Windows to
    # forward packets between interfaces. New-NetNat and interface-level
    # forwarding alone are not sufficient without this set to 1.
    Write-Host "Enabling OS-level IP routing..."
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" `
        -Name IPEnableRouter -Value 1 -Type DWord

    Write-Host "Enabling IP forwarding on both NICs..."
    Set-NetIPInterface -InterfaceAlias $ext.Name -Forwarding Enabled
    Set-NetIPInterface -InterfaceAlias $int.Name -Forwarding Enabled

    # Add 192.168.10.1 to the internal NIC so DC-B VMs (192.168.10.x) have a
    # reachable gateway on their own subnet.
    $existing = Get-NetIPAddress -InterfaceAlias $int.Name -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '192.168.10.1' }
    if (-not $existing) {
        New-NetIPAddress -InterfaceAlias $int.Name `
                         -IPAddress 192.168.10.1 `
                         -PrefixLength 24 | Out-Null
        Write-Host "Added 192.168.10.1/24 to $($int.Name) for DC-B routing."
    }

    # Configure NAT using New-NetNat (the correct approach for Server 2025).
    # The legacy netsh routing ip nat commands and Install-RemoteAccess
    # -VpnType RoutingOnly both conflict with New-NetNat and must not be used.
    Write-Host "Configuring NAT for DC-A subnet (172.16.10.0/24)..."
    if (-not (Get-NetNat -Name "LabNAT" -ErrorAction SilentlyContinue)) {
        New-NetNat -Name "LabNAT" -InternalIPInterfaceAddressPrefix "172.16.10.0/24"
        Write-Host "Created LabNAT."
    } else {
        Write-Host "LabNAT already exists - skipping."
    }

    Write-Host "Configuring NAT for DC-B subnet (192.168.10.0/24)..."
    if (-not (Get-NetNat -Name "LabNAT-DCB" -ErrorAction SilentlyContinue)) {
        New-NetNat -Name "LabNAT-DCB" -InternalIPInterfaceAddressPrefix "192.168.10.0/24"
        Write-Host "Created LabNAT-DCB."
    } else {
        Write-Host "LabNAT-DCB already exists - skipping."
    }

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

    Write-Host "Verifying NAT and routing configuration..."
    Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix, Active | Format-Table -AutoSize
    Get-NetIPInterface | Where-Object { $_.Forwarding -eq 'Enabled' } |
        Select-Object InterfaceAlias, Forwarding | Format-Table -AutoSize

    Write-Host "RRAS configuration complete."

}
