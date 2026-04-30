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
    # Write .gitconfig directly to the lab user's profile directory.
    # This is more reliable than a scheduled task approach - the scheduled
    # task can silently fail if the profile is not fully initialized when
    # the task fires, leaving git config missing or written to the wrong
    # location. Writing the file directly is deterministic and immediate.
    #
    # core.sshCommand points Git at the Windows OpenSSH client instead of
    # Git's bundled ssh.exe. Git's bundled ssh.exe does not use the Windows
    # ssh-agent, so keys loaded via ssh-add are invisible to it, causing
    # "Permission denied (publickey)" on every clone even when ssh -T works.
    # -------------------------------------------------------------------------
    $username   = $LabUser.Split('\')[-1]
    $profDir    = "C:\Users\$username"
    $gitConfig  = "$profDir\.gitconfig"

    # Ensure the profile directory exists - it should already from the
    # VS Code install step, but guard against ordering changes.
    if (-not (Test-Path $profDir)) {
        New-Item -ItemType Directory -Path $profDir -Force | Out-Null
        Write-Host "Created profile directory: $profDir"
    }

    Write-Host "Writing .gitconfig for $LabUser..."

    $gitConfigContent = @"
[user]
	name = $GitUserName
	email = $GitUserEmail
[init]
	defaultBranch = $GitDefaultBranch
[core]
	autocrlf = $GitAutoCrlf
	editor = 'C:/Program Files/Microsoft VS Code/bin/code.cmd' --wait
	sshCommand = C:/Windows/System32/OpenSSH/ssh.exe
[push]
	defaultBranch = current
"@

    [System.IO.File]::WriteAllText($gitConfig, $gitConfigContent, [System.Text.ASCIIEncoding]::new())
    Write-Host ".gitconfig written to $gitConfig"

    # Verify the file landed correctly
    if (Test-Path $gitConfig) {
        Write-Host "Git config applied:"
        Get-Content $gitConfig | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Warning ".gitconfig not found at $gitConfig after write - check profile path."
    }

    Write-Host "Git installation complete."

} -ArgumentList $Config.GitUserName, $Config.GitUserEmail, $Config.GitDefaultBranch, $Config.GitAutoClrf, "$($Config.DomainNetBIOS)\$($Config.LabUserName)"
