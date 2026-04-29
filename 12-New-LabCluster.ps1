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

$dcIP        = $ClusterDef.Nodes[0]  # resolved below from roles
$clusterName = $ClusterDef.Name
$clusterIP   = $ClusterDef.IP
$nodes       = $ClusterDef.Nodes
$shareName   = ($ClusterDef.WitnessShare -split '\\' | Where-Object { $_ -ne '' })[-1]
$witnessPath = $ClusterDef.WitnessPath
$witnessShare = $ClusterDef.WitnessShare

# Resolve node IPs from roles.json so we can connect via WinRM
$roles     = Get-Content (Join-Path $PSScriptRoot "roles.json") | ConvertFrom-Json
$nodeRoles = $roles | Where-Object { $_.Name -in $nodes }
$primaryVM = $nodeRoles | Select-Object -First 1

# ---------------------------------------------------------------------------
# Phase 1 - Create witness share on sqllabdc01
# ---------------------------------------------------------------------------
$dcRole = $roles | Where-Object { $_.Role -eq 'DC' }
Write-Host "[$clusterName] Creating witness share on $($dcRole.Name)..."

Invoke-Command -ComputerName $dcRole.IP -Credential $domainCred -ScriptBlock {
    param($WitnessPath, $ShareName, $DomainNetBIOS)

    # Create the witness directory
    if (-not (Test-Path $WitnessPath)) {
        New-Item -ItemType Directory -Path $WitnessPath -Force | Out-Null
        Write-Host "Created directory: $WitnessPath"
    } else {
        Write-Host "Exists: $WitnessPath"
    }

    # Create the SMB share if it doesn't already exist
    if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $ShareName `
                     -Path $WitnessPath `
                     -FullAccess "$DomainNetBIOS\Domain Computers", "$DomainNetBIOS\Administrator" `
                     -ErrorAction Stop | Out-Null
        Write-Host "Created share: \\$env:COMPUTERNAME\$ShareName"
    } else {
        Write-Host "Exists: share $ShareName"
    }

    # Set NTFS permissions - Domain Computers and Administrator full control
    $acl = Get-Acl $WitnessPath

    $domainComputers = New-Object System.Security.Principal.NTAccount("$DomainNetBIOS\Domain Computers")
    $domainAdmin     = New-Object System.Security.Principal.NTAccount("$DomainNetBIOS\Administrator")

    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow       = [System.Security.AccessControl.AccessControlType]::Allow
    $inherit     = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    $propagate   = [System.Security.AccessControl.PropagationFlags]::None

    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $domainComputers, $fullControl, $inherit, $propagate, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $domainAdmin, $fullControl, $inherit, $propagate, $allow)))

    Set-Acl -Path $WitnessPath -AclObject $acl
    Write-Host "NTFS permissions set on $WitnessPath"

} -ArgumentList $witnessPath, $shareName, $Config.DomainNetBIOS

# ---------------------------------------------------------------------------
# Phase 2 - Run Test-Cluster validation on the primary node
# Abort if validation fails - a failed cluster is worse than no cluster.
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Running cluster validation on nodes: $($nodes -join ', ')..."

$validationResult = Invoke-Command -ComputerName $primaryVM.IP -Credential $domainCred -ScriptBlock {
    param($Nodes, $ClusterName)

    $reportPath = "C:\Windows\Temp\ClusterValidation-$ClusterName.html"

    Write-Host "Running Test-Cluster (this takes a few minutes)..."
    $result = Test-Cluster -Node $Nodes `
                           -ReportName $reportPath `
                           -ErrorAction SilentlyContinue

    # Test-Cluster returns a report object. Check overall result.
    # Blocked = hard failure, Warning = advisory only (expected in VMs without shared storage)
    $blocked = $result | Where-Object { $_.Status -eq 'Blocked' }

    return [PSCustomObject]@{
        Blocked    = ($blocked | Measure-Object).Count
        ReportPath = $reportPath
        Results    = ($result | Select-Object Category, Status, Description)
    }

} -ArgumentList $nodes, $clusterName

if ($validationResult.Blocked -gt 0) {
    Write-Error "[$clusterName] Cluster validation failed with $($validationResult.Blocked) blocked check(s)."
    Write-Error "[$clusterName] Review the validation report at $($validationResult.ReportPath) on $($primaryVM.Name)."
    Write-Error "[$clusterName] Aborting cluster creation."
    return
}

Write-Host "[$clusterName] Validation passed (warnings about storage are expected in a VM lab)."

# ---------------------------------------------------------------------------
# Phase 3 - Create the cluster
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Creating cluster with IP $clusterIP..."

Invoke-Command -ComputerName $primaryVM.IP -Credential $domainCred -ScriptBlock {
    param($ClusterName, $ClusterIP, $Nodes)

    # Check if cluster already exists
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

# Allow AD replication and cluster object creation to settle
Write-Host "[$clusterName] Waiting for cluster computer object to propagate in AD..."
Start-Sleep -Seconds 30

# ---------------------------------------------------------------------------
# Phase 4 - Grant the cluster computer object explicit permissions on the
# witness share. The cluster object didn't exist until New-Cluster ran,
# so this must happen after creation.
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Granting cluster computer object permissions on witness share..."

Invoke-Command -ComputerName $dcRole.IP -Credential $domainCred -ScriptBlock {
    param($WitnessPath, $ShareName, $ClusterName, $DomainNetBIOS)

    $clusterAccount = "$DomainNetBIOS\$ClusterName`$"

    # Retry up to 10 times - AD replication can take a moment
    $account  = $null
    $deadline = (Get-Date).AddMinutes(5)
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
        Write-Warning "Could not resolve cluster AD object '$clusterAccount' - witness permissions may need to be set manually."
        return
    }

    # NTFS
    $acl         = Get-Acl $WitnessPath
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow       = [System.Security.AccessControl.AccessControlType]::Allow
    $inherit     = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    $propagate   = [System.Security.AccessControl.PropagationFlags]::None

    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $account, $fullControl, $inherit, $propagate, $allow)))
    Set-Acl -Path $WitnessPath -AclObject $acl
    Write-Host "NTFS: granted FullControl to $clusterAccount on $WitnessPath"

    # SMB share
    Grant-SmbShareAccess -Name $ShareName `
                         -AccountName $clusterAccount `
                         -AccessRight Full `
                         -Force | Out-Null
    Write-Host "SMB: granted FullControl to $clusterAccount on share $ShareName"

} -ArgumentList $witnessPath, $shareName, $clusterName, $Config.DomainNetBIOS

# ---------------------------------------------------------------------------
# Phase 5 - Configure file share witness quorum
# ---------------------------------------------------------------------------
Write-Host "[$clusterName] Configuring file share witness quorum: $witnessShare"

Invoke-Command -ComputerName $primaryVM.IP -Credential $domainCred -ScriptBlock {
    param($ClusterName, $WitnessShare)

    Set-ClusterQuorum -Cluster $ClusterName `
                      -FileShareWitness $WitnessShare `
                      -ErrorAction Stop | Out-Null

    $quorum = Get-ClusterQuorum -Cluster $ClusterName
    Write-Host "Quorum configured: $($quorum.QuorumType) -> $($quorum.QuorumResource)"

} -ArgumentList $clusterName, $witnessShare

Write-Host "[$clusterName] Cluster creation complete."
Write-Host "[$clusterName]   Nodes   : $($nodes -join ', ')"
Write-Host "[$clusterName]   IP      : $clusterIP"
Write-Host "[$clusterName]   Witness : $witnessShare"
