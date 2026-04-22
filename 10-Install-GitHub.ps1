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
    param($GitUserName, $GitUserEmail, $GitDefaultBranch, $GitAutoCrlf)

    Write-Host "Checking internet connectivity..."
    $connected = $false
    $deadline  = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName "central.github.com" -Port 443 `
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
    # Install GitHub Desktop
    # -------------------------------------------------------------------------
    $url  = "https://central.github.com/deployments/desktop/desktopapp/latest/win32"
    $dest = "C:\Windows\Temp\GitHubDesktopSetup.exe"

    Write-Host "Downloading GitHub Desktop..."
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing

    Write-Host "Installing GitHub Desktop silently..."
    $result = Start-Process -FilePath $dest `
        -ArgumentList "--silent" `
        -Wait -PassThru -NoNewWindow

    if ($result.ExitCode -notin @(0, 3010)) {
        throw "GitHub Desktop install failed with exit code $($result.ExitCode)"
    }
    Write-Host "GitHub Desktop installed."

    # -------------------------------------------------------------------------
    # Install Git for Windows (provides git.exe on PATH)
    # GitHub Desktop does not add git to the PATH - this is required for
    # command line usage and VS Code terminal integration.
    # -------------------------------------------------------------------------
    Write-Host "Downloading Git for Windows..."
    $gitUrl  = "https://github.com/git-for-windows/git/releases/latest/download/Git-64-bit.exe"
    $gitDest = "C:\Windows\Temp\GitSetup.exe"
    Invoke-WebRequest -Uri $gitUrl -OutFile $gitDest -UseBasicParsing

    Write-Host "Installing Git for Windows silently..."
    $gitResult = Start-Process -FilePath $gitDest `
        -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh" `
        -Wait -PassThru -NoNewWindow

    if ($gitResult.ExitCode -notin @(0, 3010)) {
        Write-Warning "Git for Windows returned exit code $($gitResult.ExitCode) - continuing anyway."
    } else {
        Write-Host "Git for Windows installed."
    }

    # -------------------------------------------------------------------------
    # Apply global git config from config.json values
    # Uses the system-level gitconfig so settings apply to all users
    # including domain accounts that log in later.
    # Note: GitHub sign-in must be completed manually the first time
    # GitHub Desktop is opened - OAuth requires interactive browser flow.
    # -------------------------------------------------------------------------
    $gitExe = "C:\Program Files\Git\cmd\git.exe"
    if (-not (Test-Path $gitExe)) {
        Write-Warning "git.exe not found at $gitExe - skipping git config."
    } else {
        Write-Host "Applying git global config..."
        Write-Host "  user.name  = $GitUserName"
        Write-Host "  user.email = $GitUserEmail"
        Write-Host "  init.defaultBranch = $GitDefaultBranch"
        Write-Host "  core.autocrlf = $GitAutoCrlf"

        & $gitExe config --system user.name  $GitUserName
        & $gitExe config --system user.email $GitUserEmail
        & $gitExe config --system init.defaultBranch $GitDefaultBranch
        & $gitExe config --system core.autocrlf $GitAutoCrlf
        & $gitExe config --system core.editor "'C:\Program Files\Microsoft VS Code\bin\code.cmd' --wait"
        & $gitExe config --system push.defaultBranch current

        Write-Host "Git config applied."
        Write-Host ""
        Write-Host "NOTE: GitHub Desktop sign-in must be completed manually."
        Write-Host "      Open GitHub Desktop and sign in via File > Options > Accounts."
    }

    Write-Host "GitHub installation complete."

} -ArgumentList $Config.GitUserName, $Config.GitUserEmail, $Config.GitDefaultBranch, $Config.GitAutoClrf
