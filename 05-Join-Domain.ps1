[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$localCred = New-Object PSCredential("Administrator",
                 (Get-Secret -Name 'LocalAdminPass' -Vault $Config.SecretsVault))
$domainCred = New-Object PSCredential(
                 "$($Config.DomainNetBIOS)\Administrator",
                 (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

# DC-B VMs (192.168.10.x) route through RRAS which was just configured.
# Allow extra time for routing to stabilize before giving up.
$winrmTimeout = if ($VMDef.IP -like '192.168.*') { 20 } else { 15 }
Write-Host "[$($VMDef.Name)] Waiting for WinRM on $($VMDef.IP) (timeout: $winrmTimeout min)..."
$deadline = (Get-Date).AddMinutes($winrmTimeout)
$wmReady  = $false
while ((Get-Date) -lt $deadline) {
    if (Test-WSMan -ComputerName $VMDef.IP -ErrorAction SilentlyContinue) {
        $wmReady = $true
        break
    }
    Start-Sleep -Seconds 15
}
if (-not $wmReady) {
    Write-Warning "[$($VMDef.Name)] WinRM did not respond within $winrmTimeout minutes - skipping domain join."
    return
}

Invoke-Command -ComputerName $VMDef.IP -Credential $localCred -ScriptBlock {
    param($Domain, $DomainCred, $OUPath)

    Write-Host "Joining domain: $Domain"
    try {
        Add-Computer -DomainName $Domain `
                     -Credential $DomainCred `
                     -OUPath $OUPath `
                     -Restart:$false `
                     -Force `
                     -ErrorAction Stop
    } catch {
        # OU may not exist yet - fall back to default computers container
        Write-Warning "Join with OUPath failed: $_"
        Write-Warning "Retrying without OUPath (default Computers container)..."
        Add-Computer -DomainName $Domain `
                     -Credential $DomainCred `
                     -Restart:$false `
                     -Force `
                     -ErrorAction Stop
    }

    Write-Host "Restarting..."
    Restart-Computer -Force

} -ArgumentList $Config.DomainFQDN, $domainCred, "OU=LabServers,DC=$($Config.DomainFQDN.Replace('.',',DC='))"

Write-Host "[$($VMDef.Name)] Waiting for rejoin..."
Start-Sleep -Seconds 45

$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    if (Test-WSMan -ComputerName $VMDef.IP -ErrorAction SilentlyContinue) {
        Write-Host "[$($VMDef.Name)] Back online and domain-joined."
        break
    }
    Start-Sleep -Seconds 15
}
