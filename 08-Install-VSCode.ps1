[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config,
    # Space-separated list of extension IDs to install.
    # Find IDs on the VS Code marketplace - format is Publisher.ExtensionName
    # Defaults to a set useful for a SQL/dev lab.
    [string]$Extensions = "ms-mssql.mssql ms-python.python ms-vscode.powershell eamodio.gitlens streetsidesoftware.code-spell-checker"
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$domainCred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
    param($Extensions, $LabUser)

    Write-Host "Checking internet connectivity..."
    $connected = $false
    $deadline  = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName "code.visualstudio.com" -Port 443 `
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
    # Install VS Code
    # -------------------------------------------------------------------------
    $url  = "https://update.code.visualstudio.com/latest/win32-x64/stable"
    $dest = "C:\Windows\Temp\VSCodeSetup.exe"

    Write-Host "Downloading Visual Studio Code..."
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing

    Write-Host "Installing Visual Studio Code silently..."
    $result = Start-Process -FilePath $dest `
        -ArgumentList "/VERYSILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath" `
        -Wait -PassThru -NoNewWindow

    if ($result.ExitCode -notin @(0, 3010)) {
        throw "VS Code install failed with exit code $($result.ExitCode)"
    }
    Write-Host "VS Code installed."

    # -------------------------------------------------------------------------
    # Disable all AI features in settings.json
    # Settings are written to the machine-wide (system) location so they apply
    # to all users including domain accounts that log in later.
    # Individual users can still override in their own settings.json.
    # -------------------------------------------------------------------------
    Write-Host "Configuring VS Code settings (disabling AI features)..."

    $settingsDir  = "C:\ProgramData\Microsoft\VS Code\data\user-data\User"
    $settingsPath = "$settingsDir\settings.json"
    New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null

    $settings = @{
        # --- Copilot / AI ---
        "github.copilot.enable"                          = @{ "*" = $false }
        "github.copilot.editor.enableAutoCompletions"    = $false
        "github.copilot.editor.enableCodeActions"        = $false
        "github.copilot.chat.enabled"                    = $false
        "github.copilot.inlineSuggest.enable"            = $false

        # --- IntelliCode ---
        "vsintellicode.modify.editor.suggestSelection"   = "automaticallyOverrodeDefaultValue"
        "editor.inlineSuggest.enabled"                   = $false

        # --- Telemetry ---
        "telemetry.telemetryLevel"                       = "off"
        "telemetry.enableCrashReporter"                  = $false
        "telemetry.enableTelemetry"                      = $false

        # --- Update / online features ---
        "update.mode"                                    = "none"
        "extensions.autoCheckUpdates"                    = $false
        "workbench.enableExperiments"                    = $false
        "workbench.settings.enableNaturalLanguageSearch" = $false

        # --- Editor quality of life ---
        "editor.formatOnSave"                            = $true
        "editor.minimap.enabled"                         = $false
        "files.autoSave"                                 = "onFocusChange"
    }

    $settings | ConvertTo-Json -Depth 5 |
        Out-File -FilePath $settingsPath -Encoding utf8 -Force
    Write-Host "VS Code settings written to $settingsPath"

    # -------------------------------------------------------------------------
    # Ensure the lab user profile exists on this machine before installing
    # extensions. Domain user profiles are created on first interactive login.
    # We force creation by running a no-op process as that user via a scheduled
    # task with a short delay, which causes Windows to initialize the profile.
    # -------------------------------------------------------------------------
    Write-Host "Ensuring lab user profile exists for $LabUser..."
    $profileScript = "'profile_created' | Out-File 'C:\Windows\Temp\ProfileDone.txt' -Force"
    $profEncoded   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($profileScript))
    $profAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $profEncoded"
    $profPrincipal = New-ScheduledTaskPrincipal -UserId $LabUser -RunLevel Highest
    $profSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName 'CreateLabUserProfile' -Action $profAction `
        -Principal $profPrincipal -Settings $profSettings -Force | Out-Null
    Remove-Item 'C:\Windows\Temp\ProfileDone.txt' -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName 'CreateLabUserProfile'
    $profDeadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $profDeadline) {
        if (Test-Path 'C:\Windows\Temp\ProfileDone.txt') { break }
        Start-Sleep -Seconds 5
    }
    Unregister-ScheduledTask -TaskName 'CreateLabUserProfile' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item 'C:\Windows\Temp\ProfileDone.txt' -Force -ErrorAction SilentlyContinue
    Write-Host "Lab user profile ready."

    # -------------------------------------------------------------------------
    # Install extensions
    # code.cmd requires a proper user profile to store extensions - it cannot
    # run correctly in a PSRemoting SYSTEM context. Use a scheduled task running
    # as the lab user who now has a profile on this machine.
    # -------------------------------------------------------------------------
    $codeCli = "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"

    if (-not (Test-Path $codeCli)) {
        Write-Warning "code.cmd not found at expected path - skipping extension install."
        Write-Warning "Extensions can be installed manually: code --install-extension <id>"
        return
    }

    $extList = $Extensions -split ' ' | Where-Object { $_ -ne '' }
    Write-Host "Installing $($extList.Count) extension(s) as $LabUser..."

    # Build a script that installs each extension and writes a done marker
    $extCommands = ($extList | ForEach-Object {
        "& '$codeCli' --install-extension $_ --force 2>&1"
    }) -join "`n"

    $taskScript = @"
$extCommands
'done' | Out-File 'C:\Windows\Temp\VSCodeExtDone.txt' -Force
"@
    $encoded   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($taskScript))
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
    # Run as the lab user so extensions install into their profile
    $principal = New-ScheduledTaskPrincipal -UserId $LabUser -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName 'VSCodeExtInstall' -Action $action `
        -Principal $principal -Settings $settings -Force | Out-Null

    Remove-Item 'C:\Windows\Temp\VSCodeExtDone.txt' -Force -ErrorAction SilentlyContinue

    Start-ScheduledTask -TaskName 'VSCodeExtInstall'
    Write-Host "Extension install task started - waiting for completion..."

    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path 'C:\Windows\Temp\VSCodeExtDone.txt') { break }
        Start-Sleep -Seconds 10
    }

    Unregister-ScheduledTask -TaskName 'VSCodeExtInstall' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item 'C:\Windows\Temp\VSCodeExtDone.txt' -Force -ErrorAction SilentlyContinue

    Write-Host "VS Code extensions installed."
    Write-Host "VS Code configuration complete."

} -ArgumentList $Extensions, "$($Config.DomainNetBIOS)\$($Config.LabUserName)"
