[CmdletBinding()]
param(
    [string]$ConfigPath = ".\config.json",
    [string]$RolesPath  = ".\roles.json"
)

# This script must be run from sqlwork01 as a domain user (sqlpadawan).
# Kerberos handles authentication to all lab VMs - no vault or explicit
# credentials are needed.

Set-Location $PSScriptRoot

$config = Get-Content $ConfigPath | ConvertFrom-Json
$roles  = Get-Content $RolesPath  | ConvertFrom-Json

$pass  = 0
$fail  = 0
$warns = 0

function Write-Pass  { param($msg) Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:pass++  }
function Write-Fail  { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:fail++  }
function Write-Warn  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:warns++ }
function Write-Check { param($msg) Write-Host "`n$msg" -ForegroundColor Cyan }

Write-Host "`n=== sqllab.local Lab Verification ===" -ForegroundColor Cyan
Write-Host "Domain : $($config.DomainFQDN)"
Write-Host "VMs    : $($roles.Count)"
Write-Host "Run    : sqlwork01 (domain-joined)`n"

# ---------------------------------------------------------------------------
# 1. Domain membership
# ---------------------------------------------------------------------------
Write-Check "[1/6] Domain membership..."
try {
    $dc = $roles | Where-Object Role -eq 'DC'
    $computers = Invoke-Command -ComputerName $dc.Name -ErrorAction Stop -ScriptBlock {
        Get-ADComputer -Filter * | Select-Object -ExpandProperty Name
    }
    $expectedNames = $roles.Name | ForEach-Object { $_.ToUpper() }
    foreach ($name in $expectedNames) {
        if ($computers -contains $name) {
            Write-Pass "$name - domain joined"
        } else {
            Write-Fail "$name - not found in AD"
        }
    }
} catch {
    Write-Fail "Could not query AD: $_"
}

# ---------------------------------------------------------------------------
# 2. SQL Server connectivity
# ---------------------------------------------------------------------------
Write-Check "[2/6] SQL Server connectivity..."
$sqlVMs = $roles | Where-Object { $_.Role -eq 'SQL' }
foreach ($vm in $sqlVMs) {
    try {
        $result = Invoke-Command -ComputerName $vm.Name -ErrorAction Stop -ScriptBlock {
            $svc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
            if (-not $svc)                 { return "Service not found" }
            if ($svc.Status -ne 'Running') { return "Service is $($svc.Status)" }
            $tcp = Test-NetConnection -ComputerName localhost -Port 1433 `
                -InformationLevel Quiet -WarningAction SilentlyContinue
            if (-not $tcp)                 { return "Port 1433 not listening" }
            return "OK"
        }
        if ($result -eq "OK") {
            Write-Pass "$($vm.Name) ($($vm.IP)) - SQL Server running, port 1433 open"
        } else {
            Write-Fail "$($vm.Name) ($($vm.IP)) - $result"
        }
    } catch {
        Write-Fail "$($vm.Name) ($($vm.IP)) - could not connect: $_"
    }
}

# Test TCP connectivity from this machine to each SQL server on port 1433.
# Validates that firewall rules and routing allow SQL connections from sqlwork01.
Write-Host "  Checking SQL port reachability from sqlwork01..."
foreach ($vm in $sqlVMs) {
    $tcp = Test-NetConnection -ComputerName $vm.IP -Port 1433 `
        -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($tcp) {
        Write-Pass "sqlwork01 -> $($vm.Name):1433 - reachable"
    } else {
        Write-Fail "sqlwork01 -> $($vm.Name):1433 - not reachable"
    }
}

# ---------------------------------------------------------------------------
# 3. Workstation software
# ---------------------------------------------------------------------------
Write-Check "[3/6] Workstation software..."

$checks = @{
    "SSMS"          = @(
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\SSMS.exe",
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Common7\IDE\Ssms.exe",
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 21\Common7\IDE\Ssms.exe",
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe"
    )
    "VS Code"       = @("C:\Program Files\Microsoft VS Code\Code.exe")
    "Visual Studio" = @(
        "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\devenv.exe",
        "C:\Program Files\Microsoft Visual Studio\2026\Community\Common7\IDE\devenv.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe"
    )
    "Git"           = @("C:\Program Files\Git\cmd\git.exe")
}

foreach ($app in $checks.Keys) {
    $found = $false
    foreach ($path in $checks[$app]) {
        if (Test-Path $path) { $found = $true; break }
    }
    # Registry fallback for Visual Studio - VS registers in the WOW6432Node hive
    if (-not $found -and $app -eq 'Visual Studio') {
        $vsReg = Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' `
            -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Visual Studio*Community*' }
        if ($vsReg) { $found = $true }
    }
    if ($found) {
        Write-Pass "$app - installed"
    } else {
        Write-Warn "$app - not found at expected path"
    }
}

# ---------------------------------------------------------------------------
# 4. Failover Clustering feature
# ---------------------------------------------------------------------------
$clusterVMs = $roles | Where-Object { $_.Clustering -eq $true }
if ($clusterVMs) {
    Write-Check "[4/6] Failover Clustering feature..."
    foreach ($vm in $clusterVMs) {
        try {
            $result = Invoke-Command -ComputerName $vm.Name -ErrorAction Stop -ScriptBlock {
                $f = Get-WindowsFeature Failover-Clustering
                return $f.InstallState.ToString()
            }
            if ($result -eq 'Installed') {
                Write-Pass "$($vm.Name) - Failover-Clustering installed"
            } else {
                Write-Fail "$($vm.Name) - Failover-Clustering state is '$result' (expected Installed)"
            }
        } catch {
            Write-Fail "$($vm.Name) - could not check clustering feature: $_"
        }
    }
} else {
    Write-Check "[4/6] Failover Clustering feature..."
    Write-Host "  No VMs configured with Clustering:true - skipping." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# 5. Failover cluster health
# ---------------------------------------------------------------------------
if ($config.Clusters) {
    Write-Check "[5/6] Failover cluster health..."

    if (-not (Get-Module -ListAvailable FailoverClusters)) {
        Write-Fail "FailoverClusters module not found - run 14-Install-FailoverClusterTools.ps1"
    } else {
        Import-Module FailoverClusters -ErrorAction SilentlyContinue

        foreach ($clusterDef in $config.Clusters) {
            try {
                $cluster = Get-Cluster -Name $clusterDef.Name -ErrorAction SilentlyContinue
                if (-not $cluster) {
                    Write-Fail "$($clusterDef.Name) - cluster not found"
                    continue
                }

                $grp    = Get-ClusterGroup  -Cluster $clusterDef.Name -Name 'Cluster Group' -ErrorAction SilentlyContinue
                $nodes  = Get-ClusterNode   -Cluster $clusterDef.Name
                $quorum = Get-ClusterQuorum -Cluster $clusterDef.Name

                if ($grp.State -eq 'Online') {
                    Write-Pass "$($clusterDef.Name) - cluster online"
                } else {
                    Write-Fail "$($clusterDef.Name) - cluster state is '$($grp.State)'"
                }

                foreach ($node in $nodes) {
                    if ($node.State -eq 'Up') {
                        Write-Pass "$($clusterDef.Name) - node $($node.Name) is Up"
                    } else {
                        Write-Fail "$($clusterDef.Name) - node $($node.Name) state is '$($node.State)'"
                    }
                }

                if ($quorum.QuorumType -like '*FileShare*') {
                    Write-Pass "$($clusterDef.Name) - file share witness configured"
                } else {
                    Write-Warn "$($clusterDef.Name) - unexpected quorum type: $($quorum.QuorumType)"
                }

            } catch {
                Write-Fail "$($clusterDef.Name) - could not query cluster: $_"
            }
        }
    }
} else {
    Write-Check "[5/6] Failover cluster health..."
    Write-Host "  No clusters defined in config.json - skipping." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# 6. Always On enabled
# ---------------------------------------------------------------------------
$alwaysOnVMs = $roles | Where-Object { $_.Clustering -eq $true -and $_.Role -eq 'SQL' }
if ($alwaysOnVMs) {
    Write-Check "[6/6] Always On Availability Groups..."
    foreach ($vm in $alwaysOnVMs) {
        try {
            $enabled = Invoke-Command -ComputerName $vm.Name -ErrorAction Stop -ScriptBlock {
                if (-not (Get-Module -ListAvailable SqlServer)) { return $null }
                Import-Module SqlServer -ErrorAction Stop
                $inst = Get-Item 'SQLSERVER:\SQL\localhost\DEFAULT' -ErrorAction Stop
                return $inst.IsHadrEnabled
            }
            if ($null -eq $enabled) {
                Write-Fail "$($vm.Name) - SqlServer module not found"
            } elseif ($enabled) {
                Write-Pass "$($vm.Name) - Always On enabled"
            } else {
                Write-Fail "$($vm.Name) - Always On is disabled"
            }
        } catch {
            Write-Fail "$($vm.Name) - could not check Always On: $_"
        }
    }
} else {
    Write-Check "[6/6] Always On Availability Groups..."
    Write-Host "  No SQL VMs with Clustering:true found - skipping." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Lab Verification Summary ===" -ForegroundColor Cyan
Write-Host "  Passed  : $pass" -ForegroundColor Green
if ($warns -gt 0) { Write-Host "  Warnings: $warns" -ForegroundColor Yellow }
if ($fail  -gt 0) { Write-Host "  Failed  : $fail"  -ForegroundColor Red    }

if ($fail -eq 0 -and $warns -eq 0) {
    Write-Host "`nAll lab checks passed. Lab is healthy." -ForegroundColor Green
} elseif ($fail -eq 0) {
    Write-Host "`nLab is functional with $warns warning(s). Review items above." -ForegroundColor Yellow
} else {
    Write-Host "`n$fail check(s) failed. Review items above before using the lab." -ForegroundColor Red
}
