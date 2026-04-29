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

    Write-Host "Checking internet connectivity..."
    $connected = $false
    $deadline  = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName "www.powershellgallery.com" -Port 443 `
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

    # Ensure NuGet provider is available - required for Install-Module to work
    # without an interactive prompt on Server 2025.
    Write-Host "Ensuring NuGet provider is present..."
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
        Write-Host "NuGet provider installed."
    } else {
        Write-Host "NuGet provider already present."
    }

    # Trust PSGallery so Install-Module does not prompt for confirmation.
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Write-Host "PSGallery set to Trusted."
    }

    Write-Host "Installing SqlServer module from PSGallery..."
    Install-Module -Name SqlServer `
                   -Force `
                   -AllowClobber `
                   -Scope AllUsers `
                   -ErrorAction Stop

    $ver = (Get-Module -ListAvailable SqlServer | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-Host "SqlServer module installed. Version: $ver"
}
