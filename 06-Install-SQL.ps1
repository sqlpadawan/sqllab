[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config,
    [Parameter(Mandatory)][string]$SQLISOPath
)
if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$domainCred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

$saSvcAcct  = "$($Config.DomainNetBIOS)\svc-sql"
$saPassword = Get-Secret -Name 'SqlSvcPass' -Vault $Config.SecretsVault -AsPlainText
$saLoginPw  = Get-Secret -Name 'SaPassword' -Vault $Config.SecretsVault -AsPlainText

$configIni = @"
[OPTIONS]
ACTION                       = Install
QUIET                        = True
QUIETSIMPLE                  = False
IACCEPTSQLSERVERLICENSETERMS = True
FEATURES                     = SQLENGINE,CONN
INSTANCENAME                 = MSSQLSERVER
INSTANCEID                   = MSSQLSERVER
SQLSVCACCOUNT                = "$saSvcAcct"
SQLSVCPASSWORD               = "$saPassword"
SQLSYSADMINACCOUNTS          = "$($Config.DomainNetBIOS)\Domain Admins"
SECURITYMODE                 = SQL
SAPWD                        = "$saLoginPw"
SQLUSERDBDIR                 = "C:\SQLData"
SQLUSERDBLOGDIR              = "C:\SQLLogs"
SQLTEMPDBDIR                 = "C:\SQLTempDB"
SQLTEMPDBLOGDIR              = "C:\SQLTempDB"
SQLBACKUPDIR                 = "C:\SQLBackups"
TCPENABLED                   = 1
NPENABLED                    = 0
BROWSERSVCSTARTUPTYPE        = Automatic
SQLSVCSTARTUPTYPE            = Automatic
UPDATEENABLED                = False
IACCEPTROPENLICENSETERMS     = True
"@

# Copy the ISO from the host to the VM using the VM's admin share (C$).
# Map a temporary PSDrive with domain credentials so Copy-Item can write to the VM.
$localISO  = "C:\Windows\Temp\SQLServer.iso"
$vmAdminShare = "\\$($VMDef.IP)\C`$"

Write-Host "[$($VMDef.Name)] Mapping VM admin share..."
New-PSDrive -Name 'VMDrive' -PSProvider FileSystem `
    -Root $vmAdminShare -Credential $domainCred -ErrorAction Stop | Out-Null

$vmISODest = "VMDrive:\Windows\Temp\SQLServer.iso"
if (-not (Test-Path $vmISODest)) {
    Write-Host "[$($VMDef.Name)] Copying SQL Server ISO to VM (this may take a few minutes)..."
    Copy-Item -Path $SQLISOPath -Destination $vmISODest -Force
    Write-Host "[$($VMDef.Name)] ISO copy complete."
} else {
    Write-Host "[$($VMDef.Name)] ISO already present on VM."
}
Remove-PSDrive -Name 'VMDrive' -Force

# Run SQL setup via a scheduled task on the VM as SYSTEM.
# This avoids the PSRemoting double-hop credential delegation issue that causes
# SQL setup to fail with a CryptographicException when run inside Invoke-Command.
Write-Host "[$($VMDef.Name)] Preparing SQL Server setup on VM..."
Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
    param($ISOPath, $IniContent)

    Write-Host "Creating SQL directories..."
    foreach ($dir in @('C:\SQLData','C:\SQLLogs','C:\SQLTempDB','C:\SQLBackups')) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Write-Host "Writing ConfigurationFile.ini..."
    $iniPath = "C:\Windows\Temp\SqlConfig.ini"
    $IniContent | Out-File $iniPath -Encoding ascii

    Write-Host "Mounting SQL Server ISO..."
    $mount  = Mount-DiskImage -ImagePath $ISOPath -PassThru
    $drive  = ($mount | Get-Volume).DriveLetter
    $setup  = "${drive}:\setup.exe"

    # Register a scheduled task to run setup as SYSTEM (avoids double-hop DPAPI issue)
    $action    = New-ScheduledTaskAction -Execute $setup `
                     -Argument "/ConfigurationFile=`"$iniPath`" /Q"
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName 'SQLSetup' -Action $action `
        -Principal $principal -Settings $settings -Force | Out-Null

    Write-Host "Starting SQL Server setup task..."
    Start-ScheduledTask -TaskName 'SQLSetup'

} -ArgumentList $localISO, $configIni

# Poll until the scheduled task completes
Write-Host "[$($VMDef.Name)] Waiting for SQL Server setup to complete (this takes 15-20 minutes)..."
$deadline = (Get-Date).AddMinutes(60)
while ((Get-Date) -lt $deadline) {
    $state = Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
        (Get-ScheduledTask -TaskName 'SQLSetup').State
    }
    if ($state -eq 'Ready' -or [int]$state -eq 3) { break }
    Write-Host "[$($VMDef.Name)] Setup running... waiting 30s"
    Start-Sleep -Seconds 30
}

# Check exit code and clean up
Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
    param($ISOPath)
    $result = (Get-ScheduledTaskInfo -TaskName 'SQLSetup').LastTaskResult
    Unregister-ScheduledTask -TaskName 'SQLSetup' -Confirm:$false -ErrorAction SilentlyContinue
    Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $ISOPath -Force -ErrorAction SilentlyContinue

    if ($result -notin @(0, 3010)) {
        throw "SQL setup failed with exit code $result. Check C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\"
    }

    Write-Host "Configuring SQL Server firewall rule..."
    New-NetFirewallRule -DisplayName "SQL Server Default Instance" `
        -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow `
        -ErrorAction SilentlyContinue | Out-Null

    Write-Host "SQL Server installation complete."
} -ArgumentList $localISO

# Install the SqlServer PowerShell module.
# Required on SQL VMs for Always On enablement (13-Enable-AlwaysOn.ps1)
# and general PowerShell-based SQL administration.
Write-Host "[$($VMDef.Name)] Installing SqlServer PowerShell module..."
Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {

    # Ensure NuGet provider is present and PSGallery is trusted.
    # On Windows Server 2025, Get-PackageProvider triggers an interactive GUI
    # prompt if NuGet is not yet registered - even with -ErrorAction SilentlyContinue.
    # Using -ForceBootstrap on Install-PackageProvider bypasses the prompt entirely
    # and is a no-op if the provider is already at or above the requested version.
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Force -ForceBootstrap -Scope AllUsers -Confirm:$false | Out-Null
    Write-Host "NuGet provider ready."

    # Trust PSGallery so Install-Module does not prompt for confirmation.
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Write-Host "Installing SqlServer module from PSGallery..."
    Install-Module -Name SqlServer `
                   -Force `
                   -AllowClobber `
                   -Scope AllUsers `
                   -ErrorAction Stop

    $ver = (Get-Module -ListAvailable SqlServer |
        Sort-Object Version -Descending |
        Select-Object -First 1).Version
    Write-Host "SqlServer module installed. Version: $ver"
}
