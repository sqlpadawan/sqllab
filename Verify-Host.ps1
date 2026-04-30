[CmdletBinding()]
param(
    [string]$ConfigPath = ".\config.json",
    [string]$RolesPath  = ".\roles.json"
)

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

Write-Host "`n=== sqllab.local Host Verification ===" -ForegroundColor Cyan
Write-Host "Domain : $($config.DomainFQDN)"
Write-Host "VMs    : $($roles.Count)"
Write-Host "Run    : Hyper-V host`n"

# ---------------------------------------------------------------------------
# 1. Hyper-V VM state
# ---------------------------------------------------------------------------
Write-Check "[1/2] VM state..."
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
Write-Check "[2/2] Host network..."

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
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Host Verification Summary ===" -ForegroundColor Cyan
Write-Host "  Passed  : $pass" -ForegroundColor Green
if ($warns -gt 0) { Write-Host "  Warnings: $warns" -ForegroundColor Yellow }
if ($fail  -gt 0) { Write-Host "  Failed  : $fail"  -ForegroundColor Red    }

if ($fail -eq 0 -and $warns -eq 0) {
    Write-Host "`nAll host checks passed." -ForegroundColor Green
} elseif ($fail -eq 0) {
    Write-Host "`nHost checks passed with $warns warning(s). Review items above." -ForegroundColor Yellow
} else {
    Write-Host "`n$fail host check(s) failed. Review items above before deploying." -ForegroundColor Red
}
