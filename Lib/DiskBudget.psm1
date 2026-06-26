#Requires -Version 5.1
<#
.SYNOPSIS
    Disk-space pre-flight check and growth reporting (Outside Voice Issue 11).

.DESCRIPTION
    Differencing disks grow as the trainee works (AD database, DNS zones, GPO
    data all land on the child VHDX, not the read-only parent), and each
    checkpoint adds another AVHDX layer. "Cheaply repeatable" was a stated
    constraint, but nothing bounds disk growth across dozens of deploy/reset
    cycles - this module makes that growth visible instead of letting the host
    fill up silently.
#>

Set-StrictMode -Version Latest

function Assert-LabDiskSpace {
    <#
    .SYNOPSIS
        Aborts with a clear error if free space on the differencing-disk
        volume is below the threshold. Call before Deploy.ps1 creates any
        new differencing disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MinFreeGB = 20
    )

    $resolvedPath = $Path
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        # Path may not exist yet on a first-ever run (e.g. VMs/ dir not created).
        # Walk up to the nearest existing ancestor so the space check still works.
        $resolvedPath = Split-Path -Path $resolvedPath -Parent
        while ($resolvedPath -and -not (Test-Path -LiteralPath $resolvedPath)) {
            $resolvedPath = Split-Path -Path $resolvedPath -Parent
        }
    }

    $drive = (Get-Item -LiteralPath $resolvedPath).PSDrive
    $freeGB = [math]::Round($drive.Free / 1GB, 1)

    if ($freeGB -lt $MinFreeGB) {
        throw "Assert-LabDiskSpace: only $freeGB GB free on drive $($drive.Name): - below the $MinFreeGB GB threshold. Free up space or lower -MinFreeDiskGB before deploying."
    }

    return $freeGB
}

function Get-LabDifferencingDiskSizes {
    <#
    .SYNOPSIS
        Reports current size of every differencing VHDX + checkpoint (AVHDX)
        file under the given VM storage root, so disk growth is visible after
        every reset rather than discovered later as "host mysteriously full."
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VmStorageRoot
    )

    if (-not (Test-Path -LiteralPath $VmStorageRoot)) {
        return @()
    }

    # -Include doesn't reliably filter when combined with -Recurse on a
    # non-wildcarded path (a long-standing PowerShell quirk - confirmed here:
    # it returned an unrelated .txt file alongside the .vhdx/.avhdx matches).
    # Filtering on Extension via Where-Object is the robust workaround.
    Get-ChildItem -LiteralPath $VmStorageRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.vhdx', '.avhdx' } |
        ForEach-Object {
            [PSCustomObject]@{
                Path   = $_.FullName
                SizeGB = [math]::Round($_.Length / 1GB, 2)
            }
        }
}

Export-ModuleMember -Function Assert-LabDiskSpace, Get-LabDifferencingDiskSizes
