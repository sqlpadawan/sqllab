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

    # Ensure NuGet provider is present and PSGallery is trusted.
    # On Windows Server 2025, Get-PackageProvider triggers an interactive GUI
    # prompt if NuGet is not yet registered - even with -ErrorAction SilentlyContinue.
    # Using -ForceBootstrap on Install-PackageProvider bypasses the prompt entirely
    # and is a no-op if the provider is already at or above the requested version.
    Write-Host "Ensuring NuGet provider is present..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Force -ForceBootstrap -Scope AllUsers -Confirm:$false | Out-Null
    Write-Host "NuGet provider ready."

    # Trust PSGallery so Install-Module does not prompt for confirmation.
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Write-Host "Installing SqlServer module from PSGallery..."
    Install-Module -Name SqlServer `
                   -Force `
                   -AllowClobber `
                   -Scope AllUsers `
                   -ErrorAction Stop

    $ver = (Get-Module -ListAvailable SqlServer | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-Host "SqlServer module installed. Version: $ver"
}
