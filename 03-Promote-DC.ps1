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

Write-Host "[$($VMDef.Name)] Waiting for reboot and AD DS to come online..."
Start-Sleep -Seconds 60

$deadline = (Get-Date).AddMinutes(20)
while ((Get-Date) -lt $deadline) {
    try {
        $domainCred = New-Object PSCredential(
            "$($Config.DomainNetBIOS)\Administrator",
            (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))
        Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred `
            -ScriptBlock { Get-ADDomain } -ErrorAction Stop | Out-Null
        Write-Host "[$($VMDef.Name)] AD DS is responding."
        break
    } catch {
        Write-Host "Waiting for AD DS... retrying in 30s"
        Start-Sleep -Seconds 30
    }
}
