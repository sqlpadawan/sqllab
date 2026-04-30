[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

# Use hostname + Kerberos when running from a domain-joined machine (sqlwork01).
# Use IP + vault credentials when running from the Hyper-V host.
$isDomainJoined = (Get-WmiObject Win32_ComputerSystem).PartOfDomain

$invokeParams = if ($isDomainJoined) {
    @{ ComputerName = $VMDef.Name }
} else {
    @{
        ComputerName = $VMDef.IP
        Credential   = New-Object PSCredential(
            "$($Config.DomainNetBIOS)\Administrator",
            (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))
    }
}

Write-Host "[$($VMDef.Name)] Enabling Always On Availability Groups..."

Invoke-Command @invokeParams -ScriptBlock {

    # Confirm SqlServer module is available before proceeding
    if (-not (Get-Module -ListAvailable SqlServer)) {
        throw "SqlServer PowerShell module not found. Ensure 06-Install-SQL.ps1 completed successfully."
    }

    Import-Module SqlServer -ErrorAction Stop

    # Resolve the actual instance registry hive name dynamically.
    # Avoids hardcoding version-specific keys like MSSQL17.MSSQLSERVER.
    $sqlRootKey  = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
    $hivePrefix  = (Get-ItemProperty "$sqlRootKey\Instance Names\SQL" -ErrorAction Stop).MSSQLSERVER
    # SQL Server 2025 stores the HADR flag at:
    #   HKLM:\...\<hive>\MSSQLServer\HADR\HADR_Enabled
    # Earlier versions used:
    #   HKLM:\...\<hive>\MSSQLServer\SuperSocketNetLib\DatabaseMirroring\IsHadrEnabled
    # Check both so the script works across versions.
    $hadrPath    = "$sqlRootKey\$hivePrefix\MSSQLServer\HADR"
    $legacyPath  = "$sqlRootKey\$hivePrefix\MSSQLServer\SuperSocketNetLib\DatabaseMirroring"

    Write-Host "Instance hive: $hivePrefix"

    # Check current HADR state via registry
    $alreadyEnabled = $false
    if (Test-Path $hadrPath) {
        $alreadyEnabled = (Get-ItemProperty $hadrPath -ErrorAction SilentlyContinue).HADR_Enabled -eq 1
    } elseif (Test-Path $legacyPath) {
        $alreadyEnabled = (Get-ItemProperty $legacyPath -ErrorAction SilentlyContinue).IsHadrEnabled -eq 1
    }

    if ($alreadyEnabled) {
        Write-Host "Always On is already enabled on this instance - skipping."
        return
    }

    # Use the machine name as the server instance.
    # 'localhost' can be misinterpreted by the SQLSERVER: PSDrive provider
    # as a path component in PSRemoting contexts, causing silent failures.
    $serverInstance = $env:COMPUTERNAME

    Write-Host "Enabling Always On (this will restart the SQL Server service)..."
    Enable-SqlAlwaysOn -ServerInstance $serverInstance -Force -ErrorAction Stop

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

    # Verify via registry - ground truth, no provider caching issues
    $verified = $false
    if (Test-Path $hadrPath) {
        $verified = (Get-ItemProperty $hadrPath -ErrorAction SilentlyContinue).HADR_Enabled -eq 1
    } elseif (Test-Path $legacyPath) {
        $verified = (Get-ItemProperty $legacyPath -ErrorAction SilentlyContinue).IsHadrEnabled -eq 1
    }

    if (-not $verified) {
        throw "Always On registry flag not set after enablement. Check SQL Server error log at C:\Program Files\Microsoft SQL Server\$hivePrefix\MSSQL\Log\ERRORLOG"
    }

    Write-Host "Always On Availability Groups enabled and verified."

    # Open the Always On endpoint port (5022) in the firewall.
    # This port is used for AG database mirroring traffic between replicas.
    New-NetFirewallRule -DisplayName "SQL Server Always On Endpoint" `
        -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Firewall rule added for AG endpoint port 5022."
}
