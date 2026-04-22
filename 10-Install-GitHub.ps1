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
    param($GitUserName, $GitUserEmail, $GitDefaultBranch, $GitAutoCrlf, $LabUser)

    Write-Host "Checking internet connectivity..."
    $connected = $false
    $deadline  = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName "api.github.com" -Port 443 `
                -InformationLevel Quiet -ErrorAction SilentlyContinue `
                -WarningAction SilentlyContinue) {
            $connected = $true
            break
        }
        Write-Host "Waiting for internet access via RRAS... retrying in 15s"
        Start-Sleep -Seconds 15
    }
    if (-not $connected) {
        throw "No internet access after 5 minutes. Verify RRAS NAT is running on sqllabdc01."
    }

    # -------------------------------------------------------------------------
    # Install Git for Windows
    # Provides git.exe on PATH for command line usage and VS Code integration.
    # Uses the GitHub API to resolve the latest release download URL so the
    # script never needs to be updated when new versions are released.
    # -------------------------------------------------------------------------
    $gitExe = "C:\Program Files\Git\cmd\git.exe"

    if (Test-Path $gitExe) {
        Write-Host "Git for Windows already installed - skipping download."
    } else {
        Write-Host "Resolving latest Git for Windows release..."
        $gitRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -UseBasicParsing
        $gitUrl     = ($gitRelease.assets | Where-Object { $_.name -like "Git-*-64-bit.exe" } | Select-Object -First 1).browser_download_url
        if (-not $gitUrl) {
            throw "Could not resolve Git for Windows download URL from GitHub API."
        }
        Write-Host "Downloading Git for Windows from $gitUrl..."
        $gitDest = "C:\Windows\Temp\GitSetup.exe"
        Invoke-WebRequest -Uri $gitUrl -OutFile $gitDest -UseBasicParsing

        Write-Host "Installing Git for Windows silently..."
        $gitResult = Start-Process -FilePath $gitDest `
            -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh" `
            -Wait -PassThru -NoNewWindow

        if ($gitResult.ExitCode -notin @(0, 3010)) {
            throw "Git for Windows install failed with exit code $($gitResult.ExitCode)"
        }
        Write-Host "Git for Windows installed."
        Remove-Item $gitDest -Force -ErrorAction SilentlyContinue
    }

    # -------------------------------------------------------------------------
    # Apply git config under the lab user account via scheduled task.
    # Uses --global so settings go into the lab user's own .gitconfig rather
    # than the system-wide gitconfig, keeping it personal to that account.
    # -------------------------------------------------------------------------
    if (-not (Test-Path $gitExe)) {
        Write-Warning "git.exe not found at $gitExe - skipping git config."
    } else {
        Write-Host "Applying git config for $LabUser..."

        $gitScript = @"
& '$gitExe' config --global user.name          '$GitUserName'
& '$gitExe' config --global user.email         '$GitUserEmail'
& '$gitExe' config --global init.defaultBranch '$GitDefaultBranch'
& '$gitExe' config --global core.autocrlf      '$GitAutoCrlf'
& '$gitExe' config --global core.editor        "'C:\Program Files\Microsoft VS Code\bin\code.cmd' --wait"
& '$gitExe' config --global push.defaultBranch current
'done' | Out-File 'C:\Windows\Temp\GitConfigDone.txt' -Force
"@
        $encoded   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($gitScript))
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $principal = New-ScheduledTaskPrincipal -UserId $LabUser -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName 'GitConfig' -Action $action `
            -Principal $principal -Settings $settings -Force | Out-Null

        Remove-Item 'C:\Windows\Temp\GitConfigDone.txt' -Force -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName 'GitConfig'

        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path 'C:\Windows\Temp\GitConfigDone.txt') { break }
            Start-Sleep -Seconds 5
        }

        Unregister-ScheduledTask -TaskName 'GitConfig' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item 'C:\Windows\Temp\GitConfigDone.txt' -Force -ErrorAction SilentlyContinue

        Write-Host "Git config applied."
    }

    Write-Host "Git installation complete."

} -ArgumentList $Config.GitUserName, $Config.GitUserEmail, $Config.GitDefaultBranch, $Config.GitAutoClrf, "$($Config.DomainNetBIOS)\$($Config.LabUserName)"
