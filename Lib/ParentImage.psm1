#Requires -Version 5.1
<#
.SYNOPSIS
    Parent VHDX protection for the differencing-disk pipeline (Code Quality Issue 3).

.DESCRIPTION
    Differencing disks depend on a parent VHDX that must never be modified or
    booted directly once children exist - if it's touched, every child VM built
    from it silently becomes invalid (confirmed via Microsoft Learn + Nakivo
    during /plan-eng-review's search check). This module enforces:
      1. A dedicated path the deploy/reset scripts never write to or attach as
         a VM disk directly.
      2. The read-only filesystem attribute, set immediately after sysprep and
         re-verified (not just set-and-trust) before every deploy run.
#>

Set-StrictMode -Version Latest

# Dedicated path convention - Deploy.ps1/Reset.ps1 must never create a VM disk
# directly inside this directory, only differencing children that point AT it.
# Defaults to F:\ when it exists: base images (15-20GB+ each after install)
# need real room, and the project's own system drive may not have it - this
# was a real gap caught by actually running Deploy.ps1 (the C: drive on the
# test host only had 8.7GB free). Falls back to a script-relative path on
# hosts with no dedicated F: drive.
$Script:ParentImageRoot = if (Test-Path -LiteralPath 'F:\') {
    'F:\WAD_env\ParentImages'
} else {
    Join-Path $PSScriptRoot '..\ParentImages'
}

$Script:ParentImageFileNames = @{
    Server2022 = 'Server2022-Base.vhdx'
    Client10   = 'Client10-Base.vhdx'
    Client11   = 'Client11-Base.vhdx'
}

# Per-OS-image path overrides — set via Set-ParentImagePath to point directly
# at a template file without requiring the root+filename convention.
$Script:ParentImagePathOverrides = @{}

function Get-ParentImagePath {
    <#
    .SYNOPSIS
        Resolves the path for a given OS image type.
        Checks per-image overrides (Set-ParentImagePath) first, then falls
        back to the root+filename convention (Set-ParentImageRoot).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Server2022', 'Client10', 'Client11')]
        [string]$OSImage
    )

    if ($Script:ParentImagePathOverrides.ContainsKey($OSImage)) {
        return $Script:ParentImagePathOverrides[$OSImage]
    }
    return (Join-Path $Script:ParentImageRoot $Script:ParentImageFileNames[$OSImage])
}

function Set-ParentImagePath {
    <#
    .SYNOPSIS
        Overrides the path for a specific OS image, pointing directly at a
        VHDX file instead of relying on the root+filename convention.
        Used by Deploy.ps1's -ParentImagePaths parameter and the wizard's
        file pickers so a template can be used in-place without copying.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Server2022', 'Client10', 'Client11')]
        [string]$OSImage,
        [Parameter(Mandatory)]
        [string]$Path
    )
    $Script:ParentImagePathOverrides[$OSImage] = $Path
}

function Protect-ParentImage {
    <#
    .SYNOPSIS
        Sets a parent VHDX read-only and verifies the attribute actually took.
    .DESCRIPTION
        Run once, immediately after the parent image is sysprepped and
        generalized - before any differencing disk is created from it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Protect-ParentImage: parent image not found at '$Path'. Build and sysprep it before protecting."
    }

    Set-ItemProperty -LiteralPath $Path -Name IsReadOnly -Value $true

    if (-not (Test-ParentImageProtected -Path $Path)) {
        throw "Protect-ParentImage: read-only attribute did not take on '$Path' after Set-ItemProperty. Check filesystem permissions before proceeding - differencing disks built from an unprotected parent are not safe."
    }
}

function Test-ParentImageProtected {
    <#
    .SYNOPSIS
        Re-reads the read-only attribute. Called both by Protect-ParentImage
        (to confirm the set took) and by Deploy.ps1 as a pre-flight check
        (to catch the parent having been silently un-protected since the
        last run, e.g. by another process or a careless manual edit).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Test-ParentImageProtected: parent image not found at '$Path'."
    }

    return (Get-Item -LiteralPath $Path).IsReadOnly
}

function Initialize-ParentImageRoot {
    <#
    .SYNOPSIS
        Ensures the dedicated parent-image directory exists. Does NOT create
        or modify any VHDX - that's a separate, manual base-image build step
        (design doc Next Steps #2-3: source ISOs, sysprep, then Protect-ParentImage).
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $Script:ParentImageRoot)) {
        New-Item -ItemType Directory -Path $Script:ParentImageRoot -Force | Out-Null
    }
}

function Set-ParentImageRoot {
    <#
    .SYNOPSIS
        Overrides the dedicated parent-image root path (e.g. for testing, or
        a host with a different drive layout than the F:\ default).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $Script:ParentImageRoot = $Path
}

Export-ModuleMember -Function Get-ParentImagePath, Set-ParentImagePath, Protect-ParentImage, Test-ParentImageProtected, Initialize-ParentImageRoot, Set-ParentImageRoot
