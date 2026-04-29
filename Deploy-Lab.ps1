[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$RolesPath,
    [string]$SQLISOPath,   # Optional override - defaults to config.json SQLISOPath
    [string]$WS2025ISO,    # Optional override - defaults to config.json WS2025ISOPath
    [switch]$SkipBaseImage
)

# Change to the project directory so all relative paths resolve correctly
Set-Location $PSScriptRoot
Write-Host "Working directory: $PSScriptRoot"

# Resolve config paths after $PSScriptRoot is available
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }
if (-not $RolesPath)  { $RolesPath  = Join-Path $PSScriptRoot "roles.json"  }

$config = Get-Content $ConfigPath | ConvertFrom-Json
$roles  = Get-Content $RolesPath  | ConvertFrom-Json

# Resolve ISO paths: CLI parameter wins; fall back to config.json
if (-not $SQLISOPath) { $SQLISOPath = $config.SQLISOPath    }
if (-not $WS2025ISO)  { $WS2025ISO  = $config.WS2025ISOPath }

# Validate ISO paths exist before doing any real work
if (-not $SkipBaseImage -and -not (Test-Path $WS2025ISO)) {
    throw "WS2025 ISO not found: '$WS2025ISO'`nUpdate WS2025ISOPath in config.json or pass -WS2025ISO."
}
if (-not (Test-Path $SQLISOPath)) {
    throw "SQL Server ISO not found: '$SQLISOPath'`nUpdate SQLISOPath in config.json or pass -SQLISOPath."
}

Write-Host "`n=== sqllab.local deployment ===" -ForegroundColor Cyan
Write-Host "Domain    : $($config.DomainFQDN)"
Write-Host "VMs       : $($roles.Count)"
Write-Host "WS2025ISO : $WS2025ISO"
Write-Host "SQLISO    : $SQLISOPath"
Write-Host "WhatIf    : $($WhatIfPreference)`n"

# Step 0 - ensure vault has required secrets
$requiredSecrets = @('LocalAdminPass','DomainAdminPass','DSSafeModePass',
                     'SqlSvcPass','SaPassword')
foreach ($s in $requiredSecrets) {
    if (-not (Get-Secret -Name $s -Vault $config.SecretsVault -ErrorAction SilentlyContinue)) {
        Write-Warning "Secret '$s' not found in vault '$($config.SecretsVault)'."
        Write-Warning "Run: Set-Secret -Name '$s' -Vault '$($config.SecretsVault)'"
    }
}

# Step 0b - run host setup to ensure vSwitches and host vNIC IP are in place.
# This is idempotent - safe to run even if setup was done previously.
Write-Host "`n[0/6] Running host setup..." -ForegroundColor Cyan
.\00-Setup-LabFolders.ps1 -WhatIf:$WhatIfPreference

# Ensure WinRM is running and TrustedHosts covers all lab IPs.
# Done before VM provisioning so PowerShell Direct and WSMan polling both work.
Write-Host "`nConfiguring WinRM TrustedHosts..." -ForegroundColor Cyan
$winrm = Get-Service -Name WinRM
if ($winrm.Status -ne 'Running') {
    Write-Host "Starting WinRM service on host..."
    Start-Service WinRM
    Set-Service WinRM -StartupType Automatic
}
$labIPs       = ($roles.IP) -join ','
$currentHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
if ($currentHosts -notmatch [regex]::Escape($labIPs)) {
    $newHosts = if ($currentHosts -and $currentHosts -ne '*') {
        "$currentHosts,$labIPs"
    } else {
        $labIPs
    }
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newHosts -Force
    Write-Host "TrustedHosts updated: $newHosts"
} else {
    Write-Host "TrustedHosts already contains lab IPs."
}

# Step 1 - build gold image
if (-not $SkipBaseImage) {
    Write-Host "`n[1/6] Building gold VHDX image..." -ForegroundColor Cyan
    if (-not (Test-Path $config.GoldVhdxPath)) {
        .\01-New-LabBaseImage.ps1 -ISOPath $WS2025ISO -OutputVhdx $config.GoldVhdxPath
    } else {
        Write-Host "Gold VHDX already exists, skipping build: $($config.GoldVhdxPath)"
    }
}

# Step 2 - provision all VMs
Write-Host "`n[2/6] Provisioning VMs..." -ForegroundColor Cyan
foreach ($vm in $roles) {
    Write-Host "  -> $($vm.Name)"
    .\02-New-LabVM.ps1 -VMDef $vm -Config $config -WhatIf:$WhatIfPreference
}

# Abort remaining stages during a WhatIf run - VMs were not created
if ($WhatIfPreference) {
    Write-Host "`n[WhatIf] Stages 3-6 skipped - no VMs were created." -ForegroundColor Yellow
    Write-Host "Re-run without -WhatIf to perform the full deployment."
    return
}

# Step 3 - promote DC
Write-Host "`n[3/6] Promoting domain controller..." -ForegroundColor Cyan
$dc = $roles | Where-Object { $_.Role -eq 'DC' }
.\03-Promote-DC.ps1 -VMDef $dc -Config $config

# Step 4 - configure RRAS on DC
Write-Host "`n[4/6] Configuring RRAS on $($dc.Name)..." -ForegroundColor Cyan
.\04-Configure-RRAS.ps1 -VMDef $dc -Config $config

# Step 5 - join members and workstation
Write-Host "`n[5/6] Joining domain members..." -ForegroundColor Cyan
$members = $roles | Where-Object { $_.Role -ne 'DC' }
foreach ($vm in $members) {
    Write-Host "  -> $($vm.Name)"
    .\05-Join-Domain.ps1 -VMDef $vm -Config $config
}

# Step 6 - role-specific post-config
Write-Host "`n[6/6] Running role post-config..." -ForegroundColor Cyan
foreach ($vm in $members) {
    foreach ($script in $vm.PostConfig | Where-Object { $_ -ne 'Join-Domain.ps1' }) {
        Write-Host "  -> $($vm.Name) : $script"
        switch ($script) {
            'Install-SQL.ps1'                  { .\06-Install-SQL.ps1                  -VMDef $vm -Config $config -SQLISOPath $SQLISOPath }
            'Install-SSMS.ps1'                 { .\07-Install-SSMS.ps1                 -VMDef $vm -Config $config }
            'Install-VSCode.ps1'               { .\08-Install-VSCode.ps1               -VMDef $vm -Config $config }
            'Install-VisualStudio.ps1'         { .\09-Install-VisualStudio.ps1         -VMDef $vm -Config $config }
            'Install-GitHub.ps1'               { .\10-Install-GitHub.ps1               -VMDef $vm -Config $config }
            'Install-SqlServerModule.ps1'      { .\11-Install-SqlServerModule.ps1      -VMDef $vm -Config $config }
            'Install-FailoverClusterTools.ps1' { .\14-Install-FailoverClusterTools.ps1 -VMDef $vm -Config $config }
        }
    }
}

# Steps 7 and 8 - cluster creation and Always On must be run manually from
# sqlwork01. The Hyper-V host is not domain-joined so it cannot run cluster
# cmdlets directly. sqlwork01 is domain-joined and has a valid Kerberos token
# to reach all SQL nodes without credential delegation issues.

Write-Host "`n=== Host deployment complete ===" -ForegroundColor Green
Write-Host "Domain controller : $($dc.IP)"
Write-Host "SQL servers       : $(($roles | Where-Object Role -eq 'SQL').IP -join ', ')"
Write-Host "Workstation       : $(($roles | Where-Object Role -eq 'Workstation').IP)"
Write-Host ""
Write-Host "Next steps - run from sqlwork01 ($($workstation.IP)) as sqlpadawan:" -ForegroundColor Yellow
Write-Host "  1. Open 64-bit PowerShell:"
Write-Host "     C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
Write-Host "  2. cd C:\Users\sqlpadawan\source\sqllab"
Write-Host "  3. Install Failover Cluster tools (first run only):"
Write-Host "     .\14-Install-FailoverClusterTools.ps1 -VMDef `$vm -Config `$config"
Write-Host "  4. Create the clusters:"
Write-Host "     foreach (`$cluster in `$config.Clusters) { .\12-New-LabCluster.ps1 -ClusterDef `$cluster -Config `$config }"
Write-Host "  5. Return to this host and run:"
Write-Host "     foreach (`$vm in `$roles | Where-Object { `$_.Clustering -and `$_.Role -eq 'SQL' }) { .\13-Enable-AlwaysOn.ps1 -VMDef `$vm -Config `$config }"
Write-Host "  6. Run .\Verify-Lab.ps1 to confirm all checks pass" 
