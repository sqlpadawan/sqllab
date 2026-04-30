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
    # Install Git for Windows (CLI only - no GUI)
    # Primary:  winget - ships with WS2025, no download URL to maintain,
    #           handles PATH automatically, smaller network footprint.
    # Fallback: GitHub API + Invoke-WebRequest if winget is unavailable or
    #           fails (e.g. App Installer service not running, air-gapped host).
    # -------------------------------------------------------------------------
    $gitExe = "C:\Program Files\Git\cmd\git.exe"

    if (Test-Path $gitExe) {
        Write-Host "Git for Windows already installed - skipping."
    } else {
        # --- Primary: winget ---
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        $installedViaWinget = $false

        if ($winget) {
            Write-Host "Installing Git via winget..."
            # --scope machine writes to Program Files and updates the system PATH,
            # which is what we need for VS Code integration and scheduled task git config.
            $wgResult = Start-Process -FilePath $winget.Source `
                -ArgumentList 'install --id Git.Git --silent --scope machine --accept-package-agreements --accept-source-agreements' `
                -Wait -PassThru -NoNewWindow

            # winget exit codes: 0 = success, -1978335189 (0x8A150013) = already installed
            if ($wgResult.ExitCode -in @(0, -1978335189)) {
                Write-Host "Git installed via winget."
                $installedViaWinget = $true
            } else {
                Write-Warning "winget exited with code $($wgResult.ExitCode) - falling back to direct download."
            }
        } else {
            Write-Host "winget not found - using direct download fallback."
        }

        # --- Fallback: GitHub API + NSIS installer ---
        if (-not $installedViaWinget -and -not (Test-Path $gitExe)) {
            Write-Host "Resolving latest Git for Windows release from GitHub API..."
            $gitRelease = Invoke-RestMethod `
                -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" `
                -UseBasicParsing
            $gitUrl = ($gitRelease.assets |
                Where-Object { $_.name -like "Git-*-64-bit.exe" } |
                Select-Object -First 1).browser_download_url
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
            Write-Host "Git for Windows installed via direct download."
            Remove-Item $gitDest -Force -ErrorAction SilentlyContinue
        }

        # Refresh PATH in this session so git.exe is visible to the config
        # step below without requiring a new shell. winget and the NSIS
        # installer both write to the system PATH but the current PSRemoting
        # session won't see it until PATH is reloaded.
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')
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
# Use Windows OpenSSH instead of Git's bundled ssh client.
# Git for Windows ships its own ssh.exe which does not use the Windows
# ssh-agent, causing authentication failures even when keys are loaded.
# Pointing core.sshCommand at the Windows OpenSSH client fixes this.
& '$gitExe' config --global core.sshCommand    'C:/Windows/System32/OpenSSH/ssh.exe'
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
            $gitState = (Get-ScheduledTask -TaskName 'GitConfig' -ErrorAction SilentlyContinue).State
            if ((Test-Path 'C:\Windows\Temp\GitConfigDone.txt') -or
                $gitState -eq 'Ready' -or [int]$gitState -eq 3) { break }
            Start-Sleep -Seconds 5
        }

        Unregister-ScheduledTask -TaskName 'GitConfig' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item 'C:\Windows\Temp\GitConfigDone.txt' -Force -ErrorAction SilentlyContinue

        Write-Host "Git config applied."
    }

    Write-Host "Git installation complete."

} -ArgumentList $Config.GitUserName, $Config.GitUserEmail, $Config.GitDefaultBranch, $Config.GitAutoClrf, "$($Config.DomainNetBIOS)\$($Config.LabUserName)"
