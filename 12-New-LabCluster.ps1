[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$ClusterDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

# This script is designed to run from sqlwork01 as a domain admin user.
# sqlwork01 is domain-joined so Kerberos handles authentication to all
# lab VMs automatically - no credential parameters or vault access needed.
# When called from Deploy-Lab.ps1 on the Hyper-V host, it remotes into
# sqlwork01 first and sqlwork01 then reaches the SQL nodes in a single hop.

if ($WhatIfPreference) {
    Write-Host "[$($ClusterDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$clusterName  = $ClusterDef.Name
$clusterIP    = $ClusterDef.IP
$nodes        = $ClusterDef.Nodes
$shareName    = ($ClusterDef.WitnessShare -split '\\' | Where-Object { $_ -ne '' })[-1]
$witnessPath  = $ClusterDef.WitnessPath
$witnessShare = $ClusterDef.WitnessShare

# Resolve roles - handle both running from sqlwork01 and from the host
$rolesPath = if (Test-Path (Join-Path $PSScriptRoot "roles.json")) {
    Join-Path $PSScriptRoot "roles.json"
} else {
    throw "roles.json not found. Run this script from the sqllab project directory."
}
$roles       = Get-Content $rolesPath | ConvertFrom-Json
$nodeRoles   = $roles | Where-Object { $_.Name -in $nodes }
$dcRole      = $roles | Where-Object { $_.Role -eq 'DC' }

# ---------------------------------------------------------------------------
# Phase 1 - Create witness share on sqllabdc01
# No -Credential needed - Kerberos from sqlwork01 handles auth
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Creating witness share on $($dcRole.Name)..."

Invoke-Command -ComputerName $dcRole.Name -ScriptBlock {
    param($WitnessPath, $ShareName, $DomainNetBIOS)

    if (-not (Test-Path $WitnessPath)) {
        New-Item -ItemType Directory -Path $WitnessPath -Force | Out-Null
        Write-Host "Created directory: $WitnessPath"
    } else {
        Write-Host "Exists: $WitnessPath"
    }

    if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $ShareName `
                     -Path $WitnessPath `
                     -FullAccess "$DomainNetBIOS\Domain Computers", "$DomainNetBIOS\Administrator" `
                     -ErrorAction Stop | Out-Null
        Write-Host "Created share: \\$env:COMPUTERNAME\$ShareName"
    } else {
        Write-Host "Exists: share $ShareName"
    }

    $acl             = Get-Acl $WitnessPath
    $fullControl     = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow           = [System.Security.AccessControl.AccessControlType]::Allow
    $inherit         = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    $propagate       = [System.Security.AccessControl.PropagationFlags]::None
    $domainComputers = New-Object System.Security.Principal.NTAccount("$DomainNetBIOS\Domain Computers")
    $domainAdmin     = New-Object System.Security.Principal.NTAccount("$DomainNetBIOS\Administrator")

    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $domainComputers, $fullControl, $inherit, $propagate, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $domainAdmin, $fullControl, $inherit, $propagate, $allow)))
    Set-Acl -Path $WitnessPath -AclObject $acl
    Write-Host "NTFS permissions set on $WitnessPath"

} -ArgumentList $witnessPath, $shareName, $Config.DomainNetBIOS

# ---------------------------------------------------------------------------
# Phase 2 - Run Test-Cluster
# Running directly on sqlwork01 - no remoting needed for this phase
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Running cluster validation on nodes: $($nodes -join ', ')..."

if (-not (Get-Module -ListAvailable FailoverClusters)) {
    throw "FailoverClusters module not found. Run 14-Install-FailoverClusterTools.ps1 first."
}

$reportPath = "C:\Windows\Temp\ClusterValidation-$clusterName.html"
$result     = Test-Cluster -Node $nodes -ReportName $reportPath -ErrorAction SilentlyContinue
$blocked    = ($result | Where-Object { $_.Status -eq 'Blocked' } | Measure-Object).Count

if ($blocked -gt 0) {
    Write-Error "[$clusterName] Cluster validation failed with $blocked blocked check(s)."
    Write-Error "[$clusterName] Review $reportPath for details."
    Write-Error "[$clusterName] Aborting cluster creation."
    return
}
Write-Host "[$clusterName] Validation passed (storage warnings are expected in a VM lab)."

# ---------------------------------------------------------------------------
# Phase 3 - Create the cluster
# Running directly on sqlwork01 as domain admin - single hop to SQL nodes
# Kerberos authenticates to all nodes without double-hop issues
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Creating cluster with IP $clusterIP..."

$existing = Get-Cluster -Name $clusterName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Cluster '$clusterName' already exists - skipping creation."
} else {
    Write-Host "Creating cluster: $clusterName ($clusterIP)"
    Write-Host "Nodes: $($nodes -join ', ')"
    New-Cluster -Name $clusterName `
                -Node $nodes `
                -StaticAddress $clusterIP `
                -NoStorage `
                -ErrorAction Stop | Out-Null
    Write-Host "Cluster '$clusterName' created successfully."
}

# Ensure ClusSvc is running and set to automatic on all nodes
Write-Host "[$clusterName] Ensuring cluster service is running on all nodes..."
foreach ($nodeVM in $nodeRoles) {
    Invoke-Command -ComputerName $nodeVM.Name -ScriptBlock {
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline) {
            $svc = Get-Service ClusSvc -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -ne 'Disabled') { break }
            Start-Sleep -Seconds 5
        }
        $svc = Get-Service ClusSvc -ErrorAction SilentlyContinue
        if ($svc.StartType -ne 'Automatic') { Set-Service ClusSvc -StartupType Automatic }
        if ($svc.Status -ne 'Running')      { Start-Service ClusSvc -ErrorAction SilentlyContinue }
        Write-Host "$env:COMPUTERNAME - ClusSvc: $((Get-Service ClusSvc).Status)"
    }
}

# Allow AD replication and cluster object creation to settle
Write-Host "[$clusterName] Waiting for cluster computer object to propagate in AD..."
Start-Sleep -Seconds 30

# ---------------------------------------------------------------------------
# Phase 4 - Grant cluster computer object permissions on witness share
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Granting cluster computer object permissions on witness share..."

Invoke-Command -ComputerName $dcRole.Name -ScriptBlock {
    param($WitnessPath, $ShareName, $ClusterName, $DomainNetBIOS)

    $clusterAccount = "$DomainNetBIOS\$ClusterName`$"
    $account        = $null
    $deadline       = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        try {
            $account = New-Object System.Security.Principal.NTAccount($clusterAccount)
            $account.Translate([System.Security.Principal.SecurityIdentifier]) | Out-Null
            break
        } catch {
            Write-Host "Waiting for cluster AD object '$clusterAccount'..."
            Start-Sleep -Seconds 15
        }
    }

    if (-not $account) {
        Write-Warning "Could not resolve '$clusterAccount' - witness permissions may need to be set manually."
        return
    }

    $acl         = Get-Acl $WitnessPath
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow       = [System.Security.AccessControl.AccessControlType]::Allow
    $inherit     = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    $propagate   = [System.Security.AccessControl.PropagationFlags]::None

    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $account, $fullControl, $inherit, $propagate, $allow)))
    Set-Acl -Path $WitnessPath -AclObject $acl
    Write-Host "NTFS: granted FullControl to $clusterAccount on $WitnessPath"

    Grant-SmbShareAccess -Name $ShareName -AccountName $clusterAccount `
        -AccessRight Full -Force | Out-Null
    Write-Host "SMB: granted FullControl to $clusterAccount on share $ShareName"

} -ArgumentList $witnessPath, $shareName, $clusterName, $Config.DomainNetBIOS

# ---------------------------------------------------------------------------
# Phase 5 - Configure file share witness quorum
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Configuring file share witness quorum: $witnessShare"

Set-ClusterQuorum -Cluster $clusterName -FileShareWitness $witnessShare -ErrorAction Stop | Out-Null
$quorum = Get-ClusterQuorum -Cluster $clusterName
Write-Host "Quorum configured: $($quorum.QuorumType) -> $($quorum.QuorumResource)"

Write-Host "[$clusterName] Cluster creation complete."
Write-Host "[$clusterName]   Nodes   : $($nodes -join ', ')"
Write-Host "[$clusterName]   IP      : $clusterIP"
Write-Host "[$clusterName]   Witness : $witnessShare"
