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

# ---------------------------------------------------------------------------
# Phase 1 - Enable Windows features required for WSL 2
# WSL 2 requires:
#   Microsoft-Windows-Subsystem-Linux  - the WSL core
#   VirtualMachinePlatform             - required for WSL 2 kernel
# Both are disabled by default on Windows Server 2025.
# A reboot is required after enabling them before wsl.exe can register
# a distro. The script reboots the VM and waits for it to come back.
# ---------------------------------------------------------------------------
Write-Host "[$($VMDef.Name)] Enabling WSL and VirtualMachinePlatform features..."
$rebootNeeded = Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {

    $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform

    $needReboot = $false

    if ($wsl.State -ne 'Enabled') {
        Write-Host "Enabling Microsoft-Windows-Subsystem-Linux..."
        $r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux `
                 -All -NoRestart
        if ($r.RestartNeeded) { $needReboot = $true }
    } else {
        Write-Host "Microsoft-Windows-Subsystem-Linux already enabled."
    }

    if ($vmp.State -ne 'Enabled') {
        Write-Host "Enabling VirtualMachinePlatform..."
        $r = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform `
                 -All -NoRestart
        if ($r.RestartNeeded) { $needReboot = $true }
    } else {
        Write-Host "VirtualMachinePlatform already enabled."
    }

    return $needReboot
}

if ($rebootNeeded) {
    Write-Host "[$($VMDef.Name)] Reboot required - rebooting VM..."
    Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
        Restart-Computer -Force
    }

    Write-Host "[$($VMDef.Name)] Waiting for VM to come back online..."
    Start-Sleep -Seconds 45

    $deadline = (Get-Date).AddMinutes(10)
    $back = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-WSMan -ComputerName $VMDef.IP -ErrorAction SilentlyContinue) {
            $back = $true
            break
        }
        Start-Sleep -Seconds 15
    }
    if (-not $back) {
        throw "[$($VMDef.Name)] VM did not come back online within 10 minutes after WSL feature reboot."
    }
    Write-Host "[$($VMDef.Name)] VM is back online."
} else {
    Write-Host "[$($VMDef.Name)] No reboot needed - features already enabled."
}

# ---------------------------------------------------------------------------
# Phase 2 - Install WSL 2 kernel update and Ubuntu
# wsl --install is not available on Server 2025 via the inbox inbox command
# in the same way as on Windows 11. Instead:
#   1. Download and install the WSL 2 Linux kernel update package (MSI)
#   2. Set WSL default version to 2
#   3. Download and install the Ubuntu distro appx package directly from
#      the GitHub releases for ubuntu-on-wsl (canonical)
# This approach avoids needing the Microsoft Store, which is not available
# on Windows Server.
# ---------------------------------------------------------------------------
Write-Host "[$($VMDef.Name)] Installing WSL 2 kernel and Ubuntu distro..."
Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {

    Write-Host "Checking internet connectivity..."
    $connected = $false
    $deadline  = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName "aka.ms" -Port 443 `
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
    # Step 1 - WSL 2 Linux kernel update MSI
    # Required on Server 2025 - the inbox kernel is not WSL 2 capable without it.
    # -------------------------------------------------------------------------
    $kernelUrl  = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
    $kernelDest = "C:\Windows\Temp\wsl_update_x64.msi"

    Write-Host "Downloading WSL 2 kernel update..."
    Invoke-WebRequest -Uri $kernelUrl -OutFile $kernelDest -UseBasicParsing

    Write-Host "Installing WSL 2 kernel update..."
    $r = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList "/i `"$kernelDest`" /quiet /norestart" `
        -Wait -PassThru -NoNewWindow
    if ($r.ExitCode -notin @(0, 3010)) {
        throw "WSL 2 kernel update failed with exit code $($r.ExitCode)"
    }
    Remove-Item $kernelDest -Force -ErrorAction SilentlyContinue
    Write-Host "WSL 2 kernel update installed."

    # -------------------------------------------------------------------------
    # Step 2 - Set WSL default version to 2
    # -------------------------------------------------------------------------
    Write-Host "Setting WSL default version to 2..."
    wsl --set-default-version 2 | Out-Null

    # -------------------------------------------------------------------------
    # Step 3 - Install Ubuntu via appx package
    # Use the latest Ubuntu LTS appx from Canonical's GitHub releases.
    # This is the supported method for Server installs without the Store.
    # -------------------------------------------------------------------------
    Write-Host "Resolving latest Ubuntu WSL appx release..."
    $release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/canonical/ubuntu-wsl/releases/latest" `
        -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -like "*.AppxBundle" } |
        Select-Object -First 1

    if (-not $asset) {
        # Fallback to a known stable Ubuntu 24.04 appx URL
        Write-Warning "Could not resolve Ubuntu appx from GitHub API - falling back to Ubuntu 24.04 LTS direct URL."
        $ubuntuUrl  = "https://aka.ms/wslubuntu2404"
        $ubuntuDest = "C:\Windows\Temp\Ubuntu.appx"
    } else {
        $ubuntuUrl  = $asset.browser_download_url
        $ubuntuDest = "C:\Windows\Temp\$($asset.name)"
        Write-Host "Found: $($asset.name)"
    }

    Write-Host "Downloading Ubuntu appx package (this may take a few minutes)..."
    Invoke-WebRequest -Uri $ubuntuUrl -OutFile $ubuntuDest -UseBasicParsing

    Write-Host "Installing Ubuntu appx..."
    Add-AppxPackage -Path $ubuntuDest -ErrorAction Stop
    Remove-Item $ubuntuDest -Force -ErrorAction SilentlyContinue
    Write-Host "Ubuntu appx installed."

    # -------------------------------------------------------------------------
    # Step 4 - Initialize the Ubuntu distro unattended
    # Running wsl --install on a fresh distro triggers an interactive first-run
    # setup. We skip this by launching Ubuntu with a headless useradd instead,
    # creating the default user non-interactively via a scheduled task so it
    # runs in the correct session context.
    # -------------------------------------------------------------------------
    Write-Host "Initializing Ubuntu distro (first-run setup)..."

    # Trigger distro initialization - this creates the base rootfs
    # Run with a timeout; the first launch can take 1-2 minutes
    $initScript = @'
wsl --distribution Ubuntu --user root -- bash -c "echo 'WSL init complete'" 2>&1
'@
    $encoded   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($initScript))
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'WSLInit' -Action $action `
        -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'WSLInit'

    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $state = (Get-ScheduledTask -TaskName 'WSLInit').State
        if ($state -eq 'Ready' -or [int]$state -eq 3) { break }
        Start-Sleep -Seconds 10
    }
    Unregister-ScheduledTask -TaskName 'WSLInit' -Confirm:$false -ErrorAction SilentlyContinue

    # Verify distro registered
    $distros = wsl --list --quiet 2>&1
    if ($distros -match 'Ubuntu') {
        Write-Host "Ubuntu WSL distro registered successfully."
    } else {
        Write-Warning "Ubuntu distro may not have registered correctly. Check 'wsl --list' on sqlwork01."
    }

    Write-Host "WSL 2 + Ubuntu installation complete."
}
