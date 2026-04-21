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

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {

    Write-Host "Checking internet connectivity..."
    $connected = $false
    $deadline  = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName "aka.ms" -Port 443 -InformationLevel Quiet `
                -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) {
            $connected = $true
            break
        }
        Write-Host "Waiting for internet access via RRAS... retrying in 15s"
        Start-Sleep -Seconds 15
    }
    if (-not $connected) {
        throw "No internet access after 5 minutes. Verify RRAS NAT is running on sqllabdc01."
    }

    $ssmsUrl = "https://aka.ms/ssmsfullsetup"
    $dest    = "C:\Windows\Temp\SSMS-Setup.exe"

    Write-Host "Downloading SSMS..."
    Invoke-WebRequest -Uri $ssmsUrl -OutFile $dest -UseBasicParsing

    Write-Host "Installing SSMS silently..."
    $result = Start-Process -FilePath $dest `
        -ArgumentList "/install /quiet /norestart" `
        -Wait -PassThru -NoNewWindow

    if ($result.ExitCode -notin @(0, 3010)) {
        throw "SSMS install failed with exit code $($result.ExitCode)"
    }

    Write-Host "SSMS installation complete."
}
