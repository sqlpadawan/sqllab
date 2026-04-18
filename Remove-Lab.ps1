[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = ".\config.json",
    [string]$RolesPath  = ".\roles.json",
    [switch]$IncludeGoldImages,
    [switch]$Force
)

$config = Get-Content $ConfigPath | ConvertFrom-Json
$roles  = Get-Content $RolesPath  | ConvertFrom-Json

Write-Host "`n=== Remove-Lab.ps1 ===" -ForegroundColor Cyan
Write-Host "Domain : $($config.DomainFQDN)"
Write-Host "VMs    : $($roles.Count)"
if ($IncludeGoldImages) {
    Write-Warning "Gold VHDX images will also be deleted."
}
Write-Host ""

# WARNING: This script permanently destroys all lab VMs and their disks.
# All data on differencing disks will be unrecoverable.
# Recommend running Checkpoint-Lab.ps1 first if you want to preserve state.
# Use -WhatIf to preview what will be removed without making any changes.

if (-not $Force) {
    $confirm = Read-Host "Type 'yes' to confirm removal of all lab VMs and disks"
    if ($confirm -ne 'yes') {
        Write-Host "Aborted. No changes made." -ForegroundColor Yellow
        return
    }
}

$errors = [System.Collections.Generic.List[string]]::new()

foreach ($vm in $roles) {
    Write-Host "`n[$($vm.Name)] Processing..." -ForegroundColor Cyan

    $hvVM = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue

    if (-not $hvVM) {
        Write-Host "[$($vm.Name)] VM not found - skipping."
        continue
    }

    # Stop VM if running
    if ($hvVM.State -ne 'Off') {
        Write-Host "[$($vm.Name)] Stopping VM..."
        if ($PSCmdlet.ShouldProcess($vm.Name, "Stop-VM")) {
            try {
                Stop-VM -Name $vm.Name -TurnOff -Force -ErrorAction Stop
                Write-Host "[$($vm.Name)] Stopped."
            } catch {
                $msg = "[$($vm.Name)] Failed to stop: $_"
                Write-Warning $msg
                $errors.Add($msg)
                continue
            }
        }
    }

    # Remove checkpoints first - can't delete a VM with checkpoints cleanly
    $checkpoints = Get-VMSnapshot -VMName $vm.Name -ErrorAction SilentlyContinue
    if ($checkpoints) {
        Write-Host "[$($vm.Name)] Removing $($checkpoints.Count) checkpoint(s)..."
        if ($PSCmdlet.ShouldProcess($vm.Name, "Remove-VMSnapshot")) {
            try {
                $checkpoints | Remove-VMSnapshot -IncludeAllChildSnapshots -ErrorAction Stop
                # Checkpoint removal merges disks - wait for it to finish
                $deadline = (Get-Date).AddMinutes(5)
                while ((Get-Date) -lt $deadline) {
                    $merging = Get-VM -Name $vm.Name |
                        Where-Object { $_.Status -like '*Merging*' }
                    if (-not $merging) { break }
                    Write-Host "[$($vm.Name)] Waiting for checkpoint merge..."
                    Start-Sleep -Seconds 10
                }
            } catch {
                $msg = "[$($vm.Name)] Failed to remove checkpoints: $_"
                Write-Warning $msg
                $errors.Add($msg)
            }
        }
    }

    # Collect disk paths before VM is removed
    $diskPaths = (Get-VMHardDiskDrive -VMName $vm.Name).Path

    # Remove the VM
    Write-Host "[$($vm.Name)] Removing VM..."
    if ($PSCmdlet.ShouldProcess($vm.Name, "Remove-VM")) {
        try {
            Remove-VM -Name $vm.Name -Force -ErrorAction Stop
            Write-Host "[$($vm.Name)] VM removed."
        } catch {
            $msg = "[$($vm.Name)] Failed to remove VM: $_"
            Write-Warning $msg
            $errors.Add($msg)
            continue
        }
    }

    # WARNING: Deletes differencing VHDX files - this is irreversible.
    foreach ($disk in $diskPaths) {
        if (Test-Path $disk) {
            Write-Host "[$($vm.Name)] Deleting disk: $disk"
            if ($PSCmdlet.ShouldProcess($disk, "Delete VHDX")) {
                try {
                    Remove-Item -Path $disk -Force -ErrorAction Stop
                    Write-Host "[$($vm.Name)] Deleted: $disk"
                } catch {
                    $msg = "[$($vm.Name)] Failed to delete disk $disk : $_"
                    Write-Warning $msg
                    $errors.Add($msg)
                }
            }
        }
    }

    # Remove VM folder if empty
    $vmFolder = Join-Path $config.VMStoragePath $vm.Name
    if ((Test-Path $vmFolder) -and
        -not (Get-ChildItem $vmFolder -Recurse -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($vmFolder, "Remove empty VM folder")) {
            Remove-Item $vmFolder -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

# Optionally remove gold images
if ($IncludeGoldImages) {
    foreach ($vhdx in @($config.GoldVhdxPath, $config.Win11VhdxPath)) {
        if (Test-Path $vhdx) {
            # WARNING: Deletes gold base images - you will need to rebuild
            # from ISO if you want to redeploy the lab from scratch.
            Write-Host "`nDeleting gold image: $vhdx"
            if ($PSCmdlet.ShouldProcess($vhdx, "Delete gold VHDX")) {
                try {
                    Remove-Item -Path $vhdx -Force -ErrorAction Stop
                    Write-Host "Deleted: $vhdx"
                } catch {
                    $errors.Add("Failed to delete gold image $vhdx : $_")
                }
            }
        }
    }
}

# Summary
Write-Host "`n=== Removal complete ===" -ForegroundColor Green

if ($errors.Count -gt 0) {
    Write-Host "`nCompleted with $($errors.Count) error(s):" -ForegroundColor Yellow
    $errors | ForEach-Object { Write-Warning $_ }
} else {
    Write-Host "All VMs and disks removed cleanly."
}

Write-Host "`nTo redeploy the lab:"
Write-Host "  .\Deploy-Lab.ps1 -SQLISOPath 'C:\ISOs\SQLServer2022.iso' ..."
