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
    param($Extensions)

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
    # Install extensions
    # The 'code' CLI is added to PATH by the installer but the current session
    # won't see it yet - use the full path instead.
    # -------------------------------------------------------------------------
    $codeCli = "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"

    if (-not (Test-Path $codeCli)) {
        Write-Warning "code.cmd not found at expected path - skipping extension install."
        Write-Warning "Extensions can be installed manually: code --install-extension <id>"
        return
    }

    $extList = $Extensions -split ' ' | Where-Object { $_ -ne '' }
    Write-Host "Installing $($extList.Count) extension(s)..."

    foreach ($ext in $extList) {
        Write-Host "  Installing: $ext"
        $proc = Start-Process -FilePath $codeCli `
            -ArgumentList "--install-extension $ext --force" `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Warning "  Extension '$ext' returned exit code $($proc.ExitCode)"
        } else {
            Write-Host "  Installed: $ext"
        }
    }

    Write-Host "VS Code configuration complete."

} -ArgumentList $Extensions
