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

$ssmsUrl = $Config.DownloadURLs.SSMS

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
    param($SsmsUrl)

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

    # SSMS 22 uses the Visual Studio Installer bootstrapper model.
    # The bootstrapper (vs_SSMS.exe) downloads and installs SSMS via the
    # Visual Studio Installer - there is no longer a standalone MSI.
    $ssmsUrl = $SsmsUrl
    $dest    = "C:\Windows\Temp\vs_SSMS.exe"

    Write-Host "Downloading SSMS 22 bootstrapper..."
    Invoke-WebRequest -Uri $ssmsUrl -OutFile $dest -UseBasicParsing

    # Verify download succeeded and file is not empty/corrupted
    $fileSize = (Get-Item $dest).Length
    if ($fileSize -lt 1MB) {
        throw "SSMS bootstrapper download appears incomplete (size: $fileSize bytes). Check internet connectivity."
    }
    Write-Host "Bootstrapper downloaded ($([math]::Round($fileSize/1MB,1)) MB)."

    # Silent install flags for Visual Studio Installer bootstrapper:
    #   --quiet        - no UI
    #   --norestart    - suppress automatic reboot
    #   --wait         - wait for install to complete before returning
    #   --nocache      - do not cache installer files to save disk space
    Write-Host "Installing SSMS 22 silently (this takes 10-20 minutes)..."
    $result = Start-Process -FilePath $dest `
        -ArgumentList "--quiet --norestart --wait --nocache" `
        -Wait -PassThru -NoNewWindow

    # 0 = success, 3010 = reboot required
    if ($result.ExitCode -notin @(0, 3010)) {
        throw "SSMS 22 install failed with exit code $($result.ExitCode)"
    }

    if ($result.ExitCode -eq 3010) {
        Write-Warning "SSMS 22 installed successfully but requires a reboot to complete."
    } else {
        Write-Host "SSMS 22 installation complete."
    }

    Remove-Item $dest -Force -ErrorAction SilentlyContinue
} -ArgumentList $ssmsUrl
