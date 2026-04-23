[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config,
    # Space-separated list of extension IDs to install.
    # Find IDs on the VS Code marketplace - format is Publisher.ExtensionName
    # Defaults to a set useful for a SQL/dev lab.
    [string]$Extensions = "ms-mssql.mssql ms-python.python ms-vscode.powershell eamodio.gitlens"
)

if ($WhatIfPreference) {
    Write-Host "[$($VMDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$domainCred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

$vsCodeUrl = $Config.DownloadURLs.VSCode

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
    param($Extensions, $LabUser, $VSCodeUrl)

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
    $url  = $VSCodeUrl
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
    # Ensure the lab user can log on locally and has a profile on this machine.
    # Add to local Administrators, then force profile creation via UserProfile API.
    # -------------------------------------------------------------------------
    Write-Host "Configuring lab user local access and profile for $LabUser..."
    $username = $LabUser.Split('\')[-1]

    # Add lab user to local Administrators group
    try {
        $adminGroup = [ADSI]"WinNT://./Administrators,group"
        $adminGroup.Add("WinNT://$($LabUser.Replace('\', '/'))")
        Write-Host "Added $LabUser to local Administrators."
    } catch {
        Write-Host "Local Administrators: $LabUser may already be a member."
    }

    # Force Windows to initialize the user profile using the UserProfile API.
    # This avoids needing an interactive login or a scheduled task.
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class UserProfileHelper {
    [DllImport("userenv.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool CreateProfile(string pszUserSid, string pszUserName, StringBuilder pszProfilePath, uint cchProfilePath);
}
"@
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($LabUser)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
        $sb = New-Object System.Text.StringBuilder(260)
        [UserProfileHelper]::CreateProfile($sid, $username, $sb, 260) | Out-Null
        Write-Host "Profile API called for $username."
    } catch {
        Write-Warning "Profile API call failed: $_ - continuing anyway."
    }

    # Wait up to 60 seconds for the profile to be fully initialized.
    # The profile directory can appear before Windows finishes writing NTUSER.DAT,
    # which causes code.cmd to fail silently when the task runs too early.
    # Waiting for NTUSER.DAT ensures the hive is fully written before proceeding.
    $profDir  = "C:\Users\$username"
    $ntuser   = "$profDir\NTUSER.DAT"
    $profDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $profDeadline -and -not (Test-Path $ntuser)) {
        Start-Sleep -Seconds 3
    }
    if (Test-Path $ntuser) {
        Write-Host "Lab user profile fully initialized at $profDir"
    } elseif (Test-Path $profDir) {
        Write-Warning "Profile directory exists but NTUSER.DAT not found at $ntuser - proceeding anyway."
    } else {
        Write-Warning "Profile not found at $profDir - extensions may install to wrong location."
    }


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

    # Build a script that installs each extension, logs all output, and writes a done marker.
    # Logging to VSCodeExt.log lets us diagnose silent failures on subsequent runs.
    $logFile = 'C:\Windows\Temp\VSCodeExt.log'
    $extCommands = ($extList | ForEach-Object {
        "& '$codeCli' --install-extension $_ --force 2>&1 | Out-File '$logFile' -Append"
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
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue

    Start-ScheduledTask -TaskName 'VSCodeExtInstall'
    Write-Host "Extension install task started - waiting for completion..."

    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        # Check both the done marker file and task state (enum or string)
        $taskState = (Get-ScheduledTask -TaskName 'VSCodeExtInstall' -ErrorAction SilentlyContinue).State
        if ((Test-Path 'C:\Windows\Temp\VSCodeExtDone.txt') -or
            $taskState -eq 'Ready' -or [int]$taskState -eq 3) { break }
        Start-Sleep -Seconds 10
    }

    Unregister-ScheduledTask -TaskName 'VSCodeExtInstall' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item 'C:\Windows\Temp\VSCodeExtDone.txt' -Force -ErrorAction SilentlyContinue

    # Report what the task logged - surfaces any silent failures
    if (Test-Path $logFile) {
        Write-Host "Extension install log:"
        Get-Content $logFile
        Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "VS Code extensions installed."
    Write-Host "VS Code configuration complete."

} -ArgumentList $Extensions, "$($Config.DomainNetBIOS)\$($Config.LabUserName)", $vsCodeUrl
