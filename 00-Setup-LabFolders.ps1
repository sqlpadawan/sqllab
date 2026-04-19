[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

# Change to the project directory so all relative paths resolve correctly
Set-Location $PSScriptRoot
Write-Host "Working directory: $PSScriptRoot"

if (-not (Test-Path $ConfigPath)) {
    throw "config.json not found at '$ConfigPath'. Verify the file exists in the project root."
}

$config = Get-Content $ConfigPath | ConvertFrom-Json

$folders = @(
    (Split-Path $config.GoldVhdxPath),
    (Split-Path $config.Win11VhdxPath),
    $config.VMStoragePath,
    $config.DiffDiskPath
)

foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        if ($PSCmdlet.ShouldProcess($folder, "Create directory")) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Write-Host "Created: $folder"
        }
    } else {
        Write-Host "Exists:  $folder"
    }
}

Write-Host "Installing required PowerShell modules..."
if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) {
    Install-Module Microsoft.PowerShell.SecretManagement,
                  Microsoft.PowerShell.SecretStore -Force -Scope AllUsers
}

Write-Host "Enabling Hyper-V role if not present..."
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hv.State -ne 'Enabled') {
    if ($PSCmdlet.ShouldProcess("Hyper-V", "Enable Windows feature")) {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
        Write-Warning "Hyper-V enabled. Reboot required before continuing."
    }
} else {
    Write-Host "Hyper-V already enabled."
}

Write-Host "Creating virtual switches..."
if (-not (Get-VMSwitch -Name $config.vSwitchExternal -ErrorAction SilentlyContinue)) {
    $hostNIC = (Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
    if ($PSCmdlet.ShouldProcess($config.vSwitchExternal, "Create external vSwitch on $hostNIC")) {
        New-VMSwitch -Name $config.vSwitchExternal -NetAdapterName $hostNIC -AllowManagementOS $true
        Write-Host "Created external vSwitch: $($config.vSwitchExternal)"
    }
} else {
    Write-Host "Exists: vSwitch $($config.vSwitchExternal)"
}

if (-not (Get-VMSwitch -Name $config.vSwitchInternal -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($config.vSwitchInternal, "Create internal vSwitch")) {
        New-VMSwitch -Name $config.vSwitchInternal -SwitchType Internal
        Write-Host "Created internal vSwitch: $($config.vSwitchInternal)"
    }
} else {
    Write-Host "Exists: vSwitch $($config.vSwitchInternal)"
}

Write-Host "`nHost setup complete."
