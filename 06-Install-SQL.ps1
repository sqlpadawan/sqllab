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

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
    param($ISOPath, $IniContent)

    # Copy ISO from host share to local temp path so Mount-DiskImage works.
    # The $ISOPath argument is a host path - map it via the admin share.
    $localISO = "C:\Windows\Temp\SQLServer.iso"
    if (-not (Test-Path $localISO)) {
        Write-Host "Copying SQL Server ISO to VM (this may take a few minutes)..."
        Copy-Item -Path $ISOPath -Destination $localISO -Force
    } else {
        Write-Host "ISO already present at $localISO"
    }

    Write-Host "Mounting SQL Server ISO..."
    $mount = Mount-DiskImage -ImagePath $localISO -PassThru
    $drive = ($mount | Get-Volume).DriveLetter
    $setup = "${drive}:\setup.exe"

    Write-Host "Creating SQL directories..."
    foreach ($dir in @('C:\SQLData','C:\SQLLogs','C:\SQLTempDB','C:\SQLBackups')) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Write-Host "Writing ConfigurationFile.ini..."
    $iniPath = "C:\Windows\Temp\SqlConfig.ini"
    $IniContent | Out-File $iniPath -Encoding ascii

    Write-Host "Running SQL Server setup..."
    $result = Start-Process -FilePath $setup `
        -ArgumentList "/ConfigurationFile=`"$iniPath`"" `
        -Wait -PassThru -NoNewWindow

    if ($result.ExitCode -notin @(0, 3010)) {
        throw "SQL setup failed with exit code $($result.ExitCode). Check C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\"
    }

    Dismount-DiskImage -ImagePath $localISO | Out-Null
    Remove-Item $localISO -Force -ErrorAction SilentlyContinue

    Write-Host "Configuring SQL Server firewall rule..."
    New-NetFirewallRule -DisplayName "SQL Server Default Instance" `
        -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow `
        -ErrorAction SilentlyContinue | Out-Null

    Write-Host "SQL Server installation complete."

} -ArgumentList $SQLISOPath, $configIni
