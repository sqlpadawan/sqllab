[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$safeModePw = Get-Secret -Name 'DSSafeModePass' -Vault $Config.SecretsVault
$cred       = New-Object PSCredential("Administrator",
                  (Get-Secret -Name 'LocalAdminPass' -Vault $Config.SecretsVault))

Invoke-Command -ComputerName $VMDef.IP -Credential $cred -ScriptBlock {
    param($DomainFQDN, $NetBIOS, $SafePw)

    Write-Host "Installing AD DS role..."
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

    Write-Host "Promoting to domain controller: $DomainFQDN"
    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName                    $DomainFQDN `
        -DomainNetbiosName             $NetBIOS `
        -DomainMode                    WinThreshold `
        -ForestMode                    WinThreshold `
        -InstallDns:$true `
        -SafeModeAdministratorPassword $SafePw `
        -Force:$true `
        -NoRebootOnCompletion:$false

} -ArgumentList $Config.DomainFQDN, $Config.DomainNetBIOS, $safeModePw

# Install-ADDSForest reboots the VM. On some Hyper-V hosts the VM shuts down
# instead of restarting. Wait briefly then ensure it is running before polling.
Write-Host "[$($VMDef.Name)] Waiting for DC reboot..."
Start-Sleep -Seconds 30
$vmState = (Get-VM -Name $VMDef.Name).State
if ($vmState -ne 'Running') {
    Write-Host "[$($VMDef.Name)] VM is '$vmState' - starting it now..."
    Start-VM -Name $VMDef.Name
}
Write-Host "[$($VMDef.Name)] Waiting for AD DS to come online..."
Start-Sleep -Seconds 60

$domainCred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

$deadline = (Get-Date).AddMinutes(20)
$adReady  = $false
while ((Get-Date) -lt $deadline) {
    try {
        Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred `
            -ScriptBlock { Get-ADDomain } -ErrorAction Stop | Out-Null
        Write-Host "[$($VMDef.Name)] AD DS is responding."
        $adReady = $true
        break
    } catch {
        Write-Host "Waiting for AD DS... retrying in 30s"
        Start-Sleep -Seconds 30
    }
}

if (-not $adReady) {
    throw "[$($VMDef.Name)] AD DS did not respond within 20 minutes. Check the VM console."
}

# Create the LabServers OU that 05-Join-Domain.ps1 targets, and the svc-sql
# service account that 06-Install-SQL.ps1 uses. Doing this here ensures they
# exist before any member VM tries to join or SQL setup runs.
Write-Host "[$($VMDef.Name)] Creating LabServers OU and svc-sql account..."
$sqlSvcPass = Get-Secret -Name 'SqlSvcPass' -Vault $Config.SecretsVault

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
    param($DomainDN, $SqlSvcPass)

    # LabServers OU
    $ouDN = "OU=LabServers,$DomainDN"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name 'LabServers' -Path $DomainDN
        Write-Host "Created OU: $ouDN"
    } else {
        Write-Host "Exists: OU LabServers"
    }

    # svc-sql service account
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'svc-sql'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name 'svc-sql' `
                   -SamAccountName 'svc-sql' `
                   -UserPrincipalName "svc-sql@$((Get-ADDomain).DNSRoot)" `
                   -AccountPassword $SqlSvcPass `
                   -PasswordNeverExpires $true `
                   -CannotChangePassword $true `
                   -Enabled $true
        Write-Host "Created account: svc-sql"
    } else {
        Write-Host "Exists: svc-sql"
    }

} -ArgumentList "DC=$($Config.DomainFQDN.Replace('.',',DC='))", $sqlSvcPass

# Create DNS reverse lookup zones for both lab subnets.
# Reverse DNS is used by SQL Server for Kerberos authentication, linked server
# connections, and availability group configurations. Without it, nslookup and
# some SQL features produce delays or warnings.
Write-Host "[$($VMDef.Name)] Creating DNS reverse lookup zones..."
Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {

    # DC-A subnet: 172.16.10.0/24 -> reverse zone is 10.16.172.in-addr.arpa
    $zoneA = '10.16.172.in-addr.arpa'
    if (-not (Get-DnsServerZone -Name $zoneA -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkID '172.16.10.0/24' -ReplicationScope 'Forest'
        Write-Host "Created reverse zone: $zoneA"
    } else {
        Write-Host "Exists: $zoneA"
    }

    # DC-B subnet: 192.168.10.0/24 -> reverse zone is 10.168.192.in-addr.arpa
    $zoneB = '10.168.192.in-addr.arpa'
    if (-not (Get-DnsServerZone -Name $zoneB -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkID '192.168.10.0/24' -ReplicationScope 'Forest'
        Write-Host "Created reverse zone: $zoneB"
    } else {
        Write-Host "Exists: $zoneB"
    }

    # Create PTR records for the DC itself - member servers will register
    # their own PTR records automatically when they join the domain.
    $dcIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -like '172.16.*' }).IPAddress
    if ($dcIP) {
        $octet = $dcIP.Split('.')[-1]
        Add-DnsServerResourceRecordPtr -ZoneName $zoneA `
            -Name $octet -PtrDomainName "sqllabdc01.$((Get-ADDomain).DNSRoot)." `
            -ErrorAction SilentlyContinue
        Write-Host "Created PTR record: $dcIP -> sqllabdc01"
    }

    Write-Host "DNS reverse lookup zones complete."
}
