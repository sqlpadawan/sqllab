[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ISOPath,
    [Parameter(Mandatory)][string]$OutputVhdx,
    [int]   $SizeGB  = 64,
    [string]$Edition = "Windows Server 2025 Datacenter Evaluation (Desktop Experience)"
)

if (Test-Path $OutputVhdx) {
    Write-Warning "Gold VHDX already exists at $OutputVhdx. Delete it first to rebuild."
    return
}

# Helper: return the next unused drive letter starting from F
function Get-FreeDriveLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($l in [char[]]([char]'F'..[char]'Z')) {
        if ($l -notin $used) { return [string]$l }
    }
    throw "No free drive letters available (F-Z exhausted)"
}

Write-Host "Mounting ISO: $ISOPath"
$mount       = Mount-DiskImage -ImagePath $ISOPath -PassThru
$driveLetter = ($mount | Get-Volume).DriveLetter
$installWim  = "${driveLetter}:\sources\install.wim"

# Validate edition name against the WIM before doing any disk work
$wimEntry = Get-WindowsImage -ImagePath $installWim | Where-Object ImageName -eq $Edition
if (-not $wimEntry) {
    Dismount-DiskImage -ImagePath $ISOPath | Out-Null
    $available = (Get-WindowsImage -ImagePath $installWim).ImageName -join "`n  "
    throw "Edition '$Edition' not found in $installWim.`nAvailable editions:`n  $available"
}
$wimIndex = $wimEntry.ImageIndex
Write-Host "Found WIM index $wimIndex for: $Edition"

Write-Host "Creating VHDX: $OutputVhdx ($SizeGB GB)"
if ($PSCmdlet.ShouldProcess($OutputVhdx, "Create gold VHDX")) {
    try {
        # Create the VHDX and attach it
        New-VHD -Path $OutputVhdx -SizeBytes ($SizeGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null
        $disk = Mount-VHD -Path $OutputVhdx -PassThru | Get-Disk

        # Build correct GPT layout for UEFI boot:
        #   Partition 1 — EFI System Partition (ESP), 100 MB, FAT32
        #   Partition 2 — MSR, 16 MB (required by Windows GPT spec, no drive letter)
        #   Partition 3 — Windows, remainder, NTFS
        Write-Host "Partitioning disk (ESP + MSR + Windows)..."
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru | Out-Null

        $espLetter = Get-FreeDriveLetter
        $esp = New-Partition -DiskNumber $disk.Number -Size 100MB `
                   -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' `
                   -DriveLetter $espLetter
        Format-Volume -DriveLetter $espLetter -FileSystem FAT32 `
                      -NewFileSystemLabel "EFI" -Confirm:$false | Out-Null

        # MSR — no drive letter, required by GPT spec
        New-Partition -DiskNumber $disk.Number -Size 16MB `
                      -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

        $winLetter = Get-FreeDriveLetter
        $win = New-Partition -DiskNumber $disk.Number -UseMaximumSize `
                   -DriveLetter $winLetter
        Format-Volume -DriveLetter $winLetter -FileSystem NTFS `
                      -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

        Write-Host "ESP: ${espLetter}:   Windows: ${winLetter}:"

        # Apply the WIM to the Windows partition
        Write-Host "Applying WIM image (index $wimIndex)..."
        Expand-WindowsImage -ImagePath $installWim `
                            -Index $wimIndex `
                            -ApplyPath "${winLetter}:\" `
                            -LogLevel 1 | Out-Null

        # Write the UEFI bootloader to the ESP
        # /s targets the ESP drive letter, /f UEFI writes EFI boot files
        Write-Host "Making VHDX bootable..."
        $result = & bcdboot "${winLetter}:\Windows" /s "${espLetter}:" /f UEFI
        if ($LASTEXITCODE -ne 0) {
            throw "bcdboot failed (exit $LASTEXITCODE): $result"
        }
        Write-Host "bcdboot: $result"

        Dismount-VHD $OutputVhdx
    } catch {
        # Clean up the incomplete VHDX so the script can be safely re-run
        if (Get-VHD $OutputVhdx -ErrorAction SilentlyContinue) {
            Dismount-VHD $OutputVhdx -ErrorAction SilentlyContinue
        }
        Remove-Item $OutputVhdx -Force -ErrorAction SilentlyContinue
        Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue | Out-Null
        throw "Gold image build failed and was cleaned up. Error: $_"
    }
}

Dismount-DiskImage -ImagePath $ISOPath | Out-Null
Write-Host "Gold VHDX complete: $OutputVhdx"
