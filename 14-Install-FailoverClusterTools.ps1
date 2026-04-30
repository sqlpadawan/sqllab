[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

# This script runs in three contexts:
#   1. From the Hyper-V host (Deploy-Lab.ps1) - remote via IP + vault credentials
#   2. From sqlwork01 targeting another VM    - remote via hostname + Kerberos
#   3. From sqlwork01 targeting sqlwork01     - local execution (no remoting)
#
# Windows blocks WinRM loopback to the local machine by hostname, so when the
# target VM is the current machine we run the install block directly instead
# of remoting into ourselves.

$isLocalTarget = ($VMDef.Name -eq $env:COMPUTERNAME)
$isDomainJoined = (Get-WmiObject Win32_ComputerSystem).PartOfDomain

Write-Host "[$($VMDef.Name)] Installing Failover Cluster management tools..."

$installBlock = {
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

if ($isLocalTarget) {
    # Target is this machine - run locally to avoid WinRM loopback restriction.
    & $installBlock
} elseif ($isDomainJoined) {
    # Domain-joined machine targeting another VM - Kerberos handles auth.
    Invoke-Command -ComputerName $VMDef.Name -ScriptBlock $installBlock
} else {
    # Hyper-V host (not domain-joined) - use IP and vault credentials.
    $cred = New-Object PSCredential(
        "$($Config.DomainNetBIOS)\Administrator",
        (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))
    Invoke-Command -ComputerName $VMDef.IP -Credential $cred -ScriptBlock $installBlock
}
