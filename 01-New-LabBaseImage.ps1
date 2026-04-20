[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ISOPath,
    [Parameter(Mandatory)][string]$OutputVhdx,
    [int]   $SizeGB    = 64,
    [string]$Edition,
    [switch]$Win11
)

# Default edition name based on OS type if not explicitly provided
if (-not $Edition) {
    $Edition = if ($Win11) { "Windows 11 Pro" } else { "Windows Server 2025 Standard (Desktop Experience)" }
}

if (Test-Path $OutputVhdx) {
    Write-Warning "Gold VHDX already exists at $OutputVhdx. Delete it first to rebuild."
    return
}

Write-Host "Mounting ISO: $ISOPath"
$mount       = Mount-DiskImage -ImagePath $ISOPath -PassThru
$driveLetter = ($mount | Get-Volume).DriveLetter
$installWim  = "${driveLetter}:\sources\install.wim"

Write-Host "Creating VHDX: $OutputVhdx ($SizeGB GB)"
if ($PSCmdlet.ShouldProcess($OutputVhdx, "Create gold VHDX")) {
    $vhd = New-VHD -Path $OutputVhdx -SizeBytes ($SizeGB * 1GB) -Dynamic
    $vhd | Mount-VHD -Passthru | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -UseMaximumSize -AssignDriveLetter |
        Format-Volume -FileSystem NTFS -Confirm:$false | Out-Null

    $vhdDrive = (Get-VHD $OutputVhdx | Get-Disk | Get-Partition |
        Where-Object { $_.Type -eq 'Basic' } | Get-Volume).DriveLetter

    Write-Host "Applying WIM image: $Edition"
    $wimIndex = (Get-WindowsImage -ImagePath $installWim |
        Where-Object ImageName -eq $Edition).ImageIndex

    Expand-WindowsImage -ImagePath $installWim `
                        -Index $wimIndex `
                        -ApplyPath "${vhdDrive}:\" `
                        -LogLevel 1 | Out-Null

    Write-Host "Making VHDX bootable..."
    $bcdPath = "${vhdDrive}:\Windows"
    bcdboot "${bcdPath}\Windows" /s "${vhdDrive}:" /f UEFI | Out-Null

    Dismount-VHD $OutputVhdx
}

Dismount-DiskImage -ImagePath $ISOPath | Out-Null
Write-Host "Gold VHDX complete: $OutputVhdx"
