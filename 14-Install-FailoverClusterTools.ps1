[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$domainCred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

Write-Host "[$($VMDef.Name)] Installing Failover Cluster management tools..."

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {

    # RSAT-Clustering-PowerShell provides the FailoverClusters module including
    # New-Cluster, Get-Cluster, Set-ClusterQuorum, and related cmdlets.
    # Required on sqlwork01 so cluster creation and management can be driven
    # from within the domain without double-hop credential issues.
    $feature = Get-WindowsFeature RSAT-Clustering-PowerShell -ErrorAction SilentlyContinue
    if ($feature -and $feature.InstallState.ToString() -eq 'Installed') {
        Write-Host "RSAT-Clustering-PowerShell already installed - skipping."
        return
    }

    Write-Host "Installing RSAT-Clustering-PowerShell..."
    $result = Install-WindowsFeature RSAT-Clustering-PowerShell -IncludeManagementTools -ErrorAction Stop

    if ($result.Success) {
        Write-Host "RSAT-Clustering-PowerShell installed successfully."
        if ($result.RestartNeeded.Value__ -ne 0) {
            Write-Warning "A reboot may be required to complete the installation."
        }
    } else {
        throw "Failed to install RSAT-Clustering-PowerShell."
    }

    # Verify the module is now available
    if (Get-Module -ListAvailable FailoverClusters) {
        Write-Host "FailoverClusters module confirmed available."
    } else {
        Write-Warning "FailoverClusters module not found after install - a reboot may be required."
    }
}
