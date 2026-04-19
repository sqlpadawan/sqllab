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

Write-Host "[$($VMDef.Name)] Waiting for WinRM on $($VMDef.IP)..."
$deadline = (Get-Date).AddMinutes(15)
while ((Get-Date) -lt $deadline) {
    if (Test-WSMan -ComputerName $VMDef.IP -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Seconds 15
}

Invoke-Command -ComputerName $VMDef.IP -Credential $localCred -ScriptBlock {
    param($Domain, $DomainCred)

    Write-Host "Joining domain: $Domain"
    Add-Computer -DomainName $Domain `
                 -Credential $DomainCred `
                 -OUPath "OU=LabServers,DC=sqllab,DC=local" `
                 -Restart:$false `
                 -Force

    Write-Host "Restarting..."
    Restart-Computer -Force

} -ArgumentList $Config.DomainFQDN, $domainCred

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
