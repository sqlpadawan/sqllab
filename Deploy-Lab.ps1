[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$RolesPath,
    [string]$SQLISOPath,
    [string]$WS2025ISO,
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

Write-Host "`n=== sqllab.local deployment ===" -ForegroundColor Cyan
Write-Host "Domain : $($config.DomainFQDN)"
Write-Host "VMs    : $($roles.Count)"
Write-Host "WhatIf : $($WhatIfPreference)`n"

# Step 0 - ensure vault has required secrets
$requiredSecrets = @('LocalAdminPass','DomainAdminPass','DSSafeModePass',
                     'SqlSvcPass','SaPassword')
foreach ($s in $requiredSecrets) {
    if (-not (Get-Secret -Name $s -Vault $config.SecretsVault -ErrorAction SilentlyContinue)) {
        Write-Warning "Secret '$s' not found in vault '$($config.SecretsVault)'."
        Write-Warning "Run: Set-Secret -Name '$s' -Vault '$($config.SecretsVault)'"
    }
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

# Abort remaining stages during a WhatIf run — VMs were not created
if ($WhatIfPreference) {
    Write-Host "`n[WhatIf] Stages 3-6 skipped — no VMs were created." -ForegroundColor Yellow
    Write-Host "Re-run without -WhatIf to perform the full deployment."
    return
}

# Add lab VM IPs to WinRM TrustedHosts so PSRemoting works from a non-domain host
Write-Host "`nConfiguring WinRM TrustedHosts..." -ForegroundColor Cyan
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
            'Install-SQL.ps1'  { .\06-Install-SQL.ps1  -VMDef $vm -Config $config -SQLISOPath $SQLISOPath }
            'Install-SSMS.ps1' { .\07-Install-SSMS.ps1 -VMDef $vm -Config $config }
        }
    }
}

Write-Host "`n=== Deployment complete ===" -ForegroundColor Green
Write-Host "Domain controller : $($dc.IP)"
Write-Host "SQL servers       : $(($roles | Where-Object Role -eq 'SQL').IP -join ', ')"
Write-Host "Workstation       : $(($roles | Where-Object Role -eq 'Workstation').IP)"
