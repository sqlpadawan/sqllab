[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath  = ".\config.json",
    [string]$RolesPath   = ".\roles.json",
    [string]$SQLISOPath  = "C:\ISOs\SQLServer2022.iso",
    [string]$WS2022ISO   = "C:\ISOs\WindowsServer2022.iso",
    [string]$Win11ISO    = "C:\ISOs\Windows11.iso",
    [switch]$SkipBaseImage,
    [switch]$WhatIf
)

$config = Get-Content $ConfigPath | ConvertFrom-Json
$roles  = Get-Content $RolesPath  | ConvertFrom-Json

Write-Host "`n=== sqllab.local deployment ===" -ForegroundColor Cyan
Write-Host "Domain : $($config.DomainFQDN)"
Write-Host "VMs    : $($roles.Count)"
Write-Host "WhatIf : $WhatIf`n"

# Step 0 - ensure vault has required secrets
$requiredSecrets = @('LocalAdminPass','DomainAdminPass','DSSafeModePass',
                     'SqlSvcPass','SaPassword')
foreach ($s in $requiredSecrets) {
    if (-not (Get-Secret -Name $s -Vault $config.SecretsVault -ErrorAction SilentlyContinue)) {
        Write-Warning "Secret '$s' not found in vault '$($config.SecretsVault)'."
        Write-Warning "Run: Set-Secret -Name '$s' -Vault '$($config.SecretsVault)'"
    }
}

# Step 1 - build gold images
if (-not $SkipBaseImage) {
    Write-Host "`n[1/6] Building gold VHDX images..." -ForegroundColor Cyan
    if (-not (Test-Path $config.GoldVhdxPath)) {
        .\01-New-LabBaseImage.ps1 -ISOPath $WS2022ISO -OutputVhdx $config.GoldVhdxPath
    }
    if (-not (Test-Path $config.Win11VhdxPath)) {
        .\01-New-LabBaseImage.ps1 -ISOPath $Win11ISO -OutputVhdx $config.Win11VhdxPath -Win11
    }
}

# Step 2 - provision all VMs
Write-Host "`n[2/6] Provisioning VMs..." -ForegroundColor Cyan
foreach ($vm in $roles) {
    Write-Host "  -> $($vm.Name)"
    .\02-New-LabVM.ps1 -VMDef $vm -Config $config -WhatIf:$WhatIf
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
