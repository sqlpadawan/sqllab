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

$vsUrl = $Config.DownloadURLs.VisualStudio

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {
    param($VsUrl)

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

    $url  = $VsUrl
    $dest = "C:\Windows\Temp\vs_community.exe"

    Write-Host "Downloading Visual Studio Community bootstrapper..."
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing

    # Workloads:
    #   Microsoft.VisualStudio.Workload.ManagedDesktop
    #       .NET desktop development - WinForms, WPF, console apps,
    #       .NET Framework and .NET (Core) support
    #
    #   Microsoft.VisualStudio.Workload.Data
    #       Data storage and processing - SQL Server Data Tools (SSDT),
    #       LINQ to SQL, ADO.NET, Entity Framework, Azure Data Lake tools
    #
    # Individual components added on top of the workloads:
    #   Microsoft.Net.Component.4.8.TargetingPack
    #       .NET Framework 4.8 targeting pack - required for many legacy
    #       SQL Server and enterprise app projects
    #
#   Microsoft.VisualStudio.Component.SQL.SSDT
    #       SQL Server Data Tools explicitly included to ensure SSDT
    #       is present even if workload selection changes
    #
    #   Component.GitHub.VisualStudio
    #       GitHub extension for Visual Studio - clone, commit, push
    #       from within the IDE

    $args = @(
        "--quiet",
        "--norestart",
        "--wait",
        "--add Microsoft.VisualStudio.Workload.ManagedDesktop",
        "--add Microsoft.VisualStudio.Workload.Data",
        "--add Microsoft.Net.Component.4.8.TargetingPack",
        "--add Microsoft.VisualStudio.Component.SQL.SSDT",
        "--add Component.GitHub.VisualStudio",
        "--includeRecommended"
    ) -join " "

    Write-Host "Installing Visual Studio Community with:"
    Write-Host "  - .NET Desktop Development workload"
    Write-Host "  - Data Storage and Processing workload (SSDT)"
    Write-Host "  - .NET Framework 4.8 targeting pack"
    Write-Host "  - GitHub extension"
    Write-Host "This takes 20-40 minutes depending on download speed..."

    $result = Start-Process -FilePath $dest `
        -ArgumentList $args `
        -Wait -PassThru -NoNewWindow

    # 0 = success, 3010 = reboot required
    if ($result.ExitCode -notin @(0, 3010)) {
        throw "Visual Studio Community install failed with exit code $($result.ExitCode)"
    }

    if ($result.ExitCode -eq 3010) {
        Write-Warning "Visual Studio installed successfully but requires a reboot to complete."
    } else {
        Write-Host "Visual Studio Community installation complete."
    }
} -ArgumentList $vsUrl
