[CmdletBinding()]
param(
    [string]$ConfigPath = ".\config.json",
    [string]$RolesPath  = ".\roles.json"
)

Set-Location $PSScriptRoot

$config = Get-Content $ConfigPath | ConvertFrom-Json
$roles  = Get-Content $RolesPath  | ConvertFrom-Json

$domainCred = New-Object PSCredential(
    "$($config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $config.SecretsVault))

$pass  = 0
$fail  = 0
$warns = 0

function Write-Pass  { param($msg) Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:pass++  }
function Write-Fail  { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:fail++  }
function Write-Warn  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:warns++ }
function Write-Check { param($msg) Write-Host "`n$msg" -ForegroundColor Cyan }

Write-Host "`n=== sqllab.local Verification ===" -ForegroundColor Cyan
Write-Host "Domain : $($config.DomainFQDN)"
Write-Host "VMs    : $($roles.Count)`n"

# ---------------------------------------------------------------------------
# 1. Hyper-V VM state
# ---------------------------------------------------------------------------
Write-Check "[1/6] VM state..."
foreach ($vm in $roles) {
    $hvVM = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue
    if (-not $hvVM) {
        Write-Fail "$($vm.Name) - VM not found in Hyper-V"
    } elseif ($hvVM.State -ne 'Running') {
        Write-Fail "$($vm.Name) - VM state is '$($hvVM.State)' (expected Running)"
    } else {
        Write-Pass "$($vm.Name) - Running"
    }
}

# ---------------------------------------------------------------------------
# 2. Host network
# ---------------------------------------------------------------------------
Write-Check "[2/6] Host network..."

$internalNIC = Get-NetIPAddress -InterfaceAlias "*$($config.vSwitchInternal)*" `
    -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $config.HostInternalIP }
if ($internalNIC) {
    Write-Pass "Host vNIC has $($config.HostInternalIP)/24 on $($config.vSwitchInternal)"
} else {
    Write-Fail "Host vNIC missing $($config.HostInternalIP)/24 - run 00-Setup-LabFolders.ps1"
}

$dcbRoute = Get-NetRoute -DestinationPrefix '192.168.10.0/24' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -eq '172.16.10.10' }
if ($dcbRoute) {
    Write-Pass "DC-B route present: 192.168.10.0/24 via 172.16.10.10"
} else {
    Write-Warn "DC-B route missing - DC-B VMs may be unreachable from host"
}

# ---------------------------------------------------------------------------
# 3. WinRM reachability
# ---------------------------------------------------------------------------
Write-Check "[3/6] WinRM connectivity..."
foreach ($vm in $roles | Where-Object { $_.Role -ne 'DC' }) {
    if (Test-WSMan -ComputerName $vm.IP -ErrorAction SilentlyContinue) {
        Write-Pass "$($vm.Name) ($($vm.IP)) - WinRM reachable"
    } else {
        Write-Fail "$($vm.Name) ($($vm.IP)) - WinRM not responding"
    }
}
# DC - test by IP since FQDN requires Kerberos from a non-domain host
$dcIP = ($roles | Where-Object Role -eq 'DC').IP
if (Test-NetConnection -ComputerName $dcIP -Port 5985 `
        -InformationLevel Quiet -WarningAction SilentlyContinue) {
    Write-Pass "sqllabdc01 ($dcIP) - WinRM reachable"
} else {
    Write-Fail "sqllabdc01 ($dcIP) - WinRM not responding"
}

# ---------------------------------------------------------------------------
# 4. Domain membership
# ---------------------------------------------------------------------------
Write-Check "[4/6] Domain membership..."
try {
    $dcIP = ($roles | Where-Object Role -eq 'DC').IP
    $computers = Invoke-Command -ComputerName $dcIP `
        -Credential $domainCred -ErrorAction Stop -ScriptBlock {
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
# 5. SQL Server connectivity
# ---------------------------------------------------------------------------
Write-Check "[5/6] SQL Server connectivity..."
$sqlVMs = $roles | Where-Object { $_.Role -eq 'SQL' }
foreach ($vm in $sqlVMs) {
    try {
        $result = Invoke-Command -ComputerName $vm.IP -Credential $domainCred `
            -ErrorAction Stop -ScriptBlock {
            $svc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
            if (-not $svc) { return "Service not found" }
            if ($svc.Status -ne 'Running') { return "Service is $($svc.Status)" }
            # Test TCP 1433
            $tcp = Test-NetConnection -ComputerName localhost -Port 1433 `
                -InformationLevel Quiet -WarningAction SilentlyContinue
            if (-not $tcp) { return "Port 1433 not listening" }
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

# Test SQL connectivity from sqlwork01 to each SQL server
Write-Host "  Checking SQL connectivity from sqlwork01..."
$workIP = ($roles | Where-Object Name -eq 'sqlwork01').IP
foreach ($vm in $sqlVMs) {
    try {
        $result = Invoke-Command -ComputerName $workIP -Credential $domainCred `
            -ErrorAction Stop -ScriptBlock {
            param($SQLHost)
            $tcp = Test-NetConnection -ComputerName $SQLHost -Port 1433 `
                -InformationLevel Quiet -WarningAction SilentlyContinue
            return $tcp
        } -ArgumentList $vm.IP
        if ($result) {
            Write-Pass "sqlwork01 -> $($vm.Name):1433 - reachable"
        } else {
            Write-Fail "sqlwork01 -> $($vm.Name):1433 - not reachable"
        }
    } catch {
        Write-Fail "sqlwork01 -> $($vm.Name) - could not test: $_"
    }
}

# ---------------------------------------------------------------------------
# 6. Workstation software
# ---------------------------------------------------------------------------
Write-Check "[6/9] Workstation software..."
$workIP = ($roles | Where-Object Name -eq 'sqlwork01').IP
try {
    Invoke-Command -ComputerName $workIP -Credential $domainCred `
        -ErrorAction Stop -ScriptBlock {

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
                Write-Host "  [PASS] $app - installed" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] $app - not found at expected path" -ForegroundColor Yellow
            }
        }
    }
} catch {
    Write-Fail "Could not connect to sqlwork01 to check software: $_"
}

# ---------------------------------------------------------------------------
# 7. Failover Clustering feature
# ---------------------------------------------------------------------------
$clusterVMs = $roles | Where-Object { $_.Clustering -eq $true }
if ($clusterVMs) {
    Write-Check "[7/9] Failover Clustering feature..."
    foreach ($vm in $clusterVMs) {
        try {
            $result = Invoke-Command -ComputerName $vm.IP -Credential $domainCred `
                -ErrorAction Stop -ScriptBlock {
                $f = Get-WindowsFeature Failover-Clustering
                # InstallState is an enum - return as string for reliable comparison
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
    Write-Check "[7/9] Failover Clustering feature..."
    Write-Host "  No VMs configured with Clustering:true - skipping." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# 8. Failover cluster health
# ---------------------------------------------------------------------------
if ($config.Clusters) {
    Write-Check "[8/9] Failover cluster health..."

    # Ensure the FailoverClusters module is available on the host.
    # RSAT-Clustering-PowerShell is not installed by default on Hyper-V hosts.
    if (-not (Get-Module -ListAvailable FailoverClusters)) {
        Write-Host "  Installing RSAT Failover Clustering PowerShell tools on host..."
        $osInfo = Get-CimInstance Win32_OperatingSystem
        if ($osInfo.ProductType -eq 1) {
            # Windows 10/11 - use Add-WindowsCapability
            Add-WindowsCapability -Online -Name 'Rsat.FailoverCluster.Management.Tools~~~~0.0.1.0' `
                -ErrorAction SilentlyContinue | Out-Null
        } else {
            # Windows Server - use Add-WindowsFeature
            Add-WindowsFeature RSAT-Clustering-PowerShell -ErrorAction SilentlyContinue | Out-Null
        }
    }

    foreach ($clusterDef in $config.Clusters) {
        $primaryRole = $roles | Where-Object { $_.Name -eq $clusterDef.Nodes[0] }
        try {
            if (Get-Module -ListAvailable FailoverClusters) {
                # Query directly from host using cluster IP
                $cluster = Get-Cluster -Name $clusterDef.IP -ErrorAction Stop
            } else {
                # RSAT not available - remote into primary node and query locally.
                # Use -Cluster with the cluster IP to avoid name resolution issues.
                $cluster = Invoke-Command -ComputerName $primaryRole.IP -Credential $domainCred `
                    -ErrorAction Stop -ScriptBlock {
                    param($ClusterIP)
                    Get-Cluster -Name $ClusterIP -ErrorAction SilentlyContinue
                } -ArgumentList $clusterDef.IP
            }

            if (-not $cluster) {
                Write-Fail "$($clusterDef.Name) - cluster not found at $($clusterDef.IP)"
                continue
            }

            # Run all cluster queries on the primary node to avoid RSAT dependency
            $clusterResult = Invoke-Command -ComputerName $primaryRole.IP -Credential $domainCred `
                -ErrorAction Stop -ScriptBlock {
                param($ClusterIP)
                $grp    = Get-ClusterGroup    -Cluster $ClusterIP -Name 'Cluster Group' -ErrorAction SilentlyContinue
                $nodes  = Get-ClusterNode     -Cluster $ClusterIP | Select-Object Name, @{N='State';E={$_.State.ToString()}}
                $quorum = Get-ClusterQuorum   -Cluster $ClusterIP
                return [PSCustomObject]@{
                    ClusterState = $grp.State.ToString()
                    Nodes        = $nodes
                    QuorumType   = $quorum.QuorumType.ToString()
                }
            } -ArgumentList $clusterDef.IP

            if ($clusterResult.ClusterState -eq 'Online') {
                Write-Pass "$($clusterDef.Name) - cluster online"
            } else {
                Write-Fail "$($clusterDef.Name) - cluster state is '$($clusterResult.ClusterState)'"
            }

            foreach ($node in $clusterResult.Nodes) {
                if ($node.State -eq 'Up') {
                    Write-Pass "$($clusterDef.Name) - node $($node.Name) is Up"
                } else {
                    Write-Fail "$($clusterDef.Name) - node $($node.Name) state is '$($node.State)'"
                }
            }

            if ($clusterResult.QuorumType -like '*FileShare*') {
                Write-Pass "$($clusterDef.Name) - file share witness configured"
            } else {
                Write-Warn "$($clusterDef.Name) - unexpected quorum type: $($clusterResult.QuorumType)"
            }

        } catch {
            Write-Fail "$($clusterDef.Name) - could not query cluster: $_"
        }
    }
} else {
    Write-Check "[8/9] Failover cluster health..."
    Write-Host "  No clusters defined in config.json - skipping." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# 9. Always On enabled
# ---------------------------------------------------------------------------
$alwaysOnVMs = $roles | Where-Object { $_.Clustering -eq $true -and $_.Role -eq 'SQL' }
if ($alwaysOnVMs) {
    Write-Check "[9/9] Always On Availability Groups..."
    foreach ($vm in $alwaysOnVMs) {
        try {
            $enabled = Invoke-Command -ComputerName $vm.IP -Credential $domainCred `
                -ErrorAction Stop -ScriptBlock {
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
    Write-Check "[9/9] Always On Availability Groups..."
    Write-Host "  No SQL VMs with Clustering:true found - skipping." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Verification Summary ===" -ForegroundColor Cyan
Write-Host "  Passed  : $pass" -ForegroundColor Green
if ($warns -gt 0) { Write-Host "  Warnings: $warns" -ForegroundColor Yellow }
if ($fail  -gt 0) { Write-Host "  Failed  : $fail"  -ForegroundColor Red    }

if ($fail -eq 0 -and $warns -eq 0) {
    Write-Host "`nAll checks passed. Lab is healthy." -ForegroundColor Green
} elseif ($fail -eq 0) {
    Write-Host "`nLab is functional with $warns warning(s). Review items above." -ForegroundColor Yellow
} else {
    Write-Host "`n$fail check(s) failed. Review items above before using the lab." -ForegroundColor Red
}
