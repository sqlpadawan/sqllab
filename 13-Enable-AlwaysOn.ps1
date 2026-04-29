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

Write-Host "[$($VMDef.Name)] Enabling Always On Availability Groups..."

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {

    # Confirm SqlServer module is available before proceeding
    if (-not (Get-Module -ListAvailable SqlServer)) {
        throw "SqlServer PowerShell module not found. Ensure 06-Install-SQL.ps1 completed successfully."
    }

    Import-Module SqlServer -ErrorAction Stop

    # Check current state - skip if already enabled
    $instance = Get-Item 'SQLSERVER:\SQL\localhost\DEFAULT' -ErrorAction Stop
    if ($instance.IsHadrEnabled) {
        Write-Host "Always On is already enabled on this instance - skipping."
        return
    }

    Write-Host "Enabling Always On (this will restart the SQL Server service)..."
    Enable-SqlAlwaysOn -ServerInstance 'localhost' -Force -ErrorAction Stop

    # Poll until SQL Server service returns to Running state
    Write-Host "Waiting for SQL Server service to restart..."
    $deadline = (Get-Date).AddMinutes(5)
    $running  = $false
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $running = $true
            break
        }
        Start-Sleep -Seconds 5
    }

    if (-not $running) {
        throw "SQL Server service did not return to Running state within 5 minutes after enabling Always On."
    }

    Write-Host "SQL Server service is running."

    # Re-import the module after service restart to refresh the provider
    Remove-Module SqlServer -ErrorAction SilentlyContinue
    Import-Module SqlServer -ErrorAction Stop

    # Verify Always On is now enabled
    $instance = Get-Item 'SQLSERVER:\SQL\localhost\DEFAULT' -ErrorAction Stop
    if (-not $instance.IsHadrEnabled) {
        throw "Always On reports as disabled after enablement. Check SQL Server error log."
    }

    Write-Host "Always On Availability Groups enabled and verified."

    # Open the Always On endpoint port (5022) in the firewall.
    # This port is used for AG database mirroring traffic between replicas.
    New-NetFirewallRule -DisplayName "SQL Server Always On Endpoint" `
        -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Firewall rule added for AG endpoint port 5022."
}
