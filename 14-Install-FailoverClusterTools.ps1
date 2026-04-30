[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

# This script is designed to run from two contexts:
#   1. From the Hyper-V host during Deploy-Lab.ps1 - uses vault credentials
#   2. From sqlwork01 directly - uses current domain user token (no vault needed)
#
# Context is detected by checking whether this machine is domain-joined.
# If domain-joined, use the hostname and rely on Kerberos - no vault needed.
# If not domain-joined (the Hyper-V host), use the IP and vault credentials.

$isDomainJoined = (Get-WmiObject Win32_ComputerSystem).PartOfDomain

if ($isDomainJoined) {
    # Running from sqlwork01 or another domain member - Kerberos handles auth.
    # Use hostname so Kerberos SPN resolution works correctly.
    $invokeParams = @{ ComputerName = $VMDef.Name }
} else {
    # Running from the Hyper-V host - must use IP and explicit credentials.
    $invokeParams = @{
        ComputerName = $VMDef.IP
        Credential   = New-Object PSCredential(
            "$($Config.DomainNetBIOS)\Administrator",
            (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))
    }
}

Write-Host "[$($VMDef.Name)] Installing Failover Cluster management tools..."

Invoke-Command @invokeParams -ScriptBlock {

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

    if (Get-Module -ListAvailable FailoverClusters) {
        Write-Host "FailoverClusters module confirmed available."
    } else {
        Write-Warning "FailoverClusters module not found after install - a reboot may be required."
    }
}
