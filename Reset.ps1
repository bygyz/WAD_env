#Requires -Version 5.1
#Requires -Modules Hyper-V
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Resets the AD training lab to its 00-baseline checkpoint, or tears
    down VMs that never got that far, for the next trainee or attempt.

.DESCRIPTION
    Three cases per VM (test-review diagram):
      1. VM has a 00-baseline checkpoint -> Restore-VMSnapshot (normal case).
      2. VM exists but has NO checkpoint (a prior deploy failed before
         checkpointing it) -> torn down completely, not "restored," since
         there is nothing to restore to.
      3. VM doesn't exist at all -> skipped cleanly, does not fail the run
         (e.g. a trainee manually deleted it).

    Outside Voice Issue 10: restores are SEQUENTIAL with the same stagger as
    Deploy.ps1 (avoids the I/O contention decision 8 solved for deploy, just
    reapplied to the other end of the lifecycle), and the run STOPS AND
    REPORTS on the first failure rather than continuing - so a failed reset
    never silently leaves some VMs reverted and others not (which matters
    most for Domain A/B's joint trust state).

    Outside Voice Issue 11: reports differencing-disk sizes after the run so
    disk growth across repeated cycles stays visible.

.PARAMETER DomainAServerCount
.PARAMETER DomainBServerCount
.PARAMETER ClientCount
.PARAMETER NetworkConfig
.PARAMETER NameOverrides
.PARAMETER IPOverrides
    Must match whatever was passed to Deploy.ps1 for this lab instance - this
    script rebuilds the SAME VM name list to know what to look for, it does
    not discover live VMs by any other means. Get-LabVmDefinitions documents
    each of these.
#>
[CmdletBinding()]
param(
    # Must match Deploy.ps1's resolved path - see its VmStorageRoot comment.
    [string]$VmStorageRoot = $(if (Test-Path -LiteralPath 'F:\') { 'F:\WAD_env\VMs' } else { Join-Path $PSScriptRoot 'VMs' }),
    [int]$StaggerSeconds = 20,
    [int]$DomainAServerCount = 2,
    [int]$DomainBServerCount = 1,
    [int]$ClientCount = 2,
    [PSCustomObject]$NetworkConfig,
    [hashtable]$NameOverrides = @{},
    [hashtable]$IPOverrides = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Lib\Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lib\DiskBudget.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lib\VmDefinitions.psm1') -Force

function Format-ResultsSummary {
    param([hashtable]$Results)
    return ($Results.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
}

function Reset-OneVm {
    <#
    .SYNOPSIS
        Restores or tears down a single VM. Returns one of:
        'Restored', 'TornDown', 'Skipped'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$VmDefinition,
        [Parameter(Mandatory)][string]$VmStorageRoot
    )

    $name = $VmDefinition.Name
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue

    if (-not $vm) {
        Write-LabLog "  '$name' does not exist - skipping cleanly (not a failure)." -Level 'WARN'
        return 'Skipped'
    }

    $snapshot = Get-VMSnapshot -VMName $name -Name '00-baseline' -ErrorAction SilentlyContinue

    if ($snapshot) {
        if ($vm.State -ne 'Off') {
            Stop-VM -Name $name -TurnOff -Force
        }
        Restore-VMSnapshot -VMName $name -Name '00-baseline' -Confirm:$false
        Start-VM -Name $name
        Write-LabLog "  '$name' restored to 00-baseline and restarted."
        return 'Restored'
    }
    else {
        Write-LabLog "  '$name' has no 00-baseline checkpoint (a prior deploy likely failed before reaching it) - tearing down instead of restoring." -Level 'WARN'
        if ($vm.State -ne 'Off') {
            Stop-VM -Name $name -TurnOff -Force
        }
        Remove-VM -Name $name -Force

        $vmDir = Join-Path $VmStorageRoot $name
        if (Test-Path -LiteralPath $vmDir) {
            Remove-Item -LiteralPath $vmDir -Recurse -Force
        }
        Write-LabLog "  '$name' torn down (VM + differencing disk removed)."
        return 'TornDown'
    }
}

$logPath = Start-LabLog -RunType 'Reset'
$results = @{}

try {
    Write-LabLog "Reset run starting. Log: $logPath"
    $vmDefs = if ($NetworkConfig) {
        Get-LabVmDefinitions -DomainAServerCount $DomainAServerCount -DomainBServerCount $DomainBServerCount `
            -ClientCount $ClientCount -NetworkConfig $NetworkConfig -NameOverrides $NameOverrides -IPOverrides $IPOverrides
    }
    else {
        Get-LabVmDefinitions -DomainAServerCount $DomainAServerCount -DomainBServerCount $DomainBServerCount `
            -ClientCount $ClientCount -NameOverrides $NameOverrides -IPOverrides $IPOverrides
    }

    foreach ($vm in $vmDefs) {
        Write-LabLog "Resetting $($vm.Name)..."
        try {
            $results[$vm.Name] = Reset-OneVm -VmDefinition $vm -VmStorageRoot $VmStorageRoot
        }
        catch {
            # Stop-and-report on first failure (Outside Voice Issue 10) - do NOT
            # continue to the next VM, since a partial reset across the
            # Domain A/B trust topology can leave a confusing mixed state.
            Write-LabLog "Reset FAILED on '$($vm.Name)': $($_.Exception.Message)" -Level 'ERROR'
            Write-LabLog "Results so far: $(Format-ResultsSummary -Results $results)" -Level 'WARN'
            Write-LabLog "Remaining VMs were NOT processed: $(($vmDefs.Name | Where-Object { -not $results.ContainsKey($_) }) -join ', ')" -Level 'WARN'
            throw
        }

        if ($vm -ne $vmDefs[-1]) {
            Write-LabLog "  Staggering ${StaggerSeconds}s before next VM."
            Start-Sleep -Seconds $StaggerSeconds
        }
    }

    Write-LabLog "Reset complete: $(Format-ResultsSummary -Results $results)"

    $sizes = Get-LabDifferencingDiskSizes -VmStorageRoot $VmStorageRoot
    if ($sizes) {
        Write-LabLog '--- Differencing disk sizes after reset ---'
        foreach ($s in $sizes) {
            Write-LabLog ("  {0,6:N2} GB  {1}" -f $s.SizeGB, $s.Path)
        }
        $totalGB = [math]::Round((($sizes | Measure-Object -Property SizeGB -Sum).Sum), 2)
        Write-LabLog "  Total: $totalGB GB across $($sizes.Count) file(s)."
    }
}
finally {
    Stop-LabLog
}
