[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][PSCustomObject]$ClusterDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

if ($WhatIfPreference) {
    Write-Host "[$($ClusterDef.Name)] WhatIf: would run $(Split-Path $PSCommandPath -Leaf)"
    return
}

$domainCred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

$clusterName  = $ClusterDef.Name
$clusterIP    = $ClusterDef.IP
$nodes        = $ClusterDef.Nodes
$shareName    = ($ClusterDef.WitnessShare -split '\\' | Where-Object { $_ -ne '' })[-1]
$witnessPath  = $ClusterDef.WitnessPath
$witnessShare = $ClusterDef.WitnessShare

# Resolve roles
$roles       = Get-Content (Join-Path $PSScriptRoot "roles.json") | ConvertFrom-Json
$nodeRoles   = $roles | Where-Object { $_.Name -in $nodes }
$dcRole      = $roles | Where-Object { $_.Role -eq 'DC' }
$workstation = $roles | Where-Object { $_.Name -eq 'sqlwork01' }

# ---------------------------------------------------------------------------
# Phase 1 - Create witness share on sqllabdc01
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Creating witness share on $($dcRole.Name)..."

Invoke-Command -ComputerName $dcRole.IP -Credential $domainCred -ScriptBlock {
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
# Phase 2 - Run Test-Cluster from sqlwork01.
# sqlwork01 is domain-joined so Kerberos flows naturally to all SQL nodes.
# No double-hop issue - this is a single hop from sqlwork01 to each node.
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Running cluster validation from sqlwork01..."

$blocked = Invoke-Command -ComputerName $workstation.IP -Credential $domainCred -ScriptBlock {
    param($Nodes, $ClusterName)

    if (-not (Get-Module -ListAvailable FailoverClusters)) {
        throw "FailoverClusters module not found on sqlwork01. Run 14-Install-FailoverClusterTools.ps1 first."
    }

    $reportPath = "C:\Windows\Temp\ClusterValidation-$ClusterName.html"
    Write-Host "Running Test-Cluster on nodes: $($Nodes -join ', ')..."
    $result  = Test-Cluster -Node $Nodes -ReportName $reportPath -ErrorAction SilentlyContinue
    $blocked = ($result | Where-Object { $_.Status -eq 'Blocked' } | Measure-Object).Count
    Write-Host "Validation complete. Blocked checks: $blocked"
    return $blocked
} -ArgumentList $nodes, $clusterName

if ($blocked -gt 0) {
    Write-Error "[$clusterName] Cluster validation failed with $blocked blocked check(s). Aborting."
    return
}
Write-Host "[$clusterName] Validation passed (storage warnings are expected in a VM lab)."

# ---------------------------------------------------------------------------
# Phase 3 - Create the cluster from sqlwork01.
# Running New-Cluster from a domain-joined workstation gives it a proper
# Kerberos token. It can authenticate to all nodes in a single hop without
# any credential delegation or CredSSP required.
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Creating cluster from sqlwork01 with IP $clusterIP..."

Invoke-Command -ComputerName $workstation.IP -Credential $domainCred -ScriptBlock {
    param($ClusterName, $ClusterIP, $Nodes)

    if (-not (Get-Module -ListAvailable FailoverClusters)) {
        throw "FailoverClusters module not found on sqlwork01."
    }

    $existing = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Cluster '$ClusterName' already exists - skipping creation."
        return
    }

    Write-Host "Creating cluster: $ClusterName ($ClusterIP)"
    Write-Host "Nodes: $($Nodes -join ', ')"
    New-Cluster -Name $ClusterName `
                -Node $Nodes `
                -StaticAddress $ClusterIP `
                -NoStorage `
                -ErrorAction Stop | Out-Null
    Write-Host "Cluster '$ClusterName' created successfully."

} -ArgumentList $clusterName, $clusterIP, $nodes

# Ensure ClusSvc is running and set to automatic on all nodes
Write-Host "[$clusterName] Ensuring cluster service is running on all nodes..."
foreach ($nodeVM in $nodeRoles) {
    Invoke-Command -ComputerName $nodeVM.IP -Credential $domainCred -ScriptBlock {
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

Invoke-Command -ComputerName $dcRole.IP -Credential $domainCred -ScriptBlock {
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
# Phase 5 - Configure file share witness quorum from sqlwork01
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Configuring file share witness quorum: $witnessShare"

Invoke-Command -ComputerName $workstation.IP -Credential $domainCred -ScriptBlock {
    param($ClusterName, $WitnessShare)
    Set-ClusterQuorum -Cluster $ClusterName -FileShareWitness $WitnessShare -ErrorAction Stop | Out-Null
    $quorum = Get-ClusterQuorum -Cluster $ClusterName
    Write-Host "Quorum configured: $($quorum.QuorumType) -> $($quorum.QuorumResource)"
} -ArgumentList $clusterName, $witnessShare

Write-Host "[$clusterName] Cluster creation complete."
Write-Host "[$clusterName]   Nodes   : $($nodes -join ', ')"
Write-Host "[$clusterName]   IP      : $clusterIP"
Write-Host "[$clusterName]   Witness : $witnessShare"
