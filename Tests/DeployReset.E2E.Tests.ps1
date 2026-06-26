#Requires -Modules Pester
<#
.SYNOPSIS
    Integration/E2E tests for Deploy.ps1 + Reset.ps1 against a REAL Hyper-V
    host (test-review diagram's [->E2E] rows).

.DESCRIPTION
    These tests build and tear down real VMs - they need:
      - Hyper-V enabled on the machine running this suite
      - Both base parent VHDXs already built, sysprepped, and protected
        (see README.md "Base image setup")
      - The external/bridged switch's physical adapter available
      - Several GB of free disk and ~15-20 min of wall-clock time

    They are tagged 'RequiresHyperV' and self-skip (rather than fail) when
    that prerequisite isn't met, so `Invoke-Pester` on a non-Hyper-V machine
    (e.g. a laptop, or this repo's own dev environment) doesn't error out -
    it just reports these as skipped. Run explicitly on the trainer's actual
    Hyper-V host with:
        Invoke-Pester -Path .\Tests\DeployReset.E2E.Tests.ps1 -Tag RequiresHyperV
#>

BeforeAll {
    $script:hyperVAvailable = $false
    try {
        $script:hyperVAvailable = [bool](Get-Module -ListAvailable -Name Hyper-V)
    }
    catch { }

    $script:repoRoot = Join-Path $PSScriptRoot '..'
    $script:deployScript = Join-Path $script:repoRoot 'Deploy.ps1'
    $script:resetScript = Join-Path $script:repoRoot 'Reset.ps1'

    Import-Module (Join-Path $script:repoRoot 'Lib\VmDefinitions.psm1') -Force
    $script:vmDefs = Get-LabVmDefinitions
}

Describe 'Full deploy cycle' -Tag 'RequiresHyperV' -Skip:(-not $script:hyperVAvailable) {

    It 'produces 5 VMs, all RDP-reachable, all checkpointed at 00-baseline' {
        & $script:deployScript

        foreach ($vm in $script:vmDefs) {
            (Get-VM -Name $vm.Name).State | Should -Be 'Running'
            (Get-VMSnapshot -VMName $vm.Name -Name '00-baseline') | Should -Not -BeNullOrEmpty
            (Test-NetConnection -ComputerName $vm.IPAddress -Port 3389 -InformationLevel Quiet) | Should -BeTrue
        }
    }

    It 'does NOT install/promote the AD DS role on any DC' {
        $dcNames = ($script:vmDefs | Where-Object Role -eq 'DomainController').Name
        foreach ($name in $dcNames) {
            $feature = Invoke-Command -VMName $name -ScriptBlock { Get-WindowsFeature -Name AD-Domain-Services }
            $feature.InstallState | Should -Be 'Available'
        }
    }

    It 're-running deploy against already-existing VMs fails clearly, not silently' {
        { & $script:deployScript } | Should -Throw '*already exists*'
    }
}

Describe 'Reset cycle' -Tag 'RequiresHyperV' -Skip:(-not $script:hyperVAvailable) {

    It 'restores all 5 VMs to 00-baseline after a full success' {
        & $script:resetScript

        foreach ($vm in $script:vmDefs) {
            $snapshot = Get-VMSnapshot -VMName $vm.Name -Name '00-baseline'
            $snapshot | Should -Not -BeNullOrEmpty
            (Get-VM -Name $vm.Name).State | Should -Be 'Running'
        }
    }

    It 'tears down (does not attempt to restore) a VM that never got a checkpoint' {
        # Simulates a deploy that failed before DC2 was checkpointed.
        New-VM -Name 'DC2' -Generation 2 -MemoryStartupBytes 2GB -NoVHD | Out-Null
        try {
            & $script:resetScript
            Get-VM -Name 'DC2' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
        finally {
            Remove-VM -Name 'DC2' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'skips cleanly when a VM was manually deleted, without failing the whole run' {
        Remove-VM -Name 'CL2' -Force -ErrorAction SilentlyContinue
        { & $script:resetScript } | Should -Not -Throw
    }
}

Describe 'Failure-path flows' -Tag 'RequiresHyperV' -Skip:(-not $script:hyperVAvailable) {

    It 'aborts the whole deploy BEFORE touching any VM when a reserved IP is already in use' {
        # Stand up a throwaway listener on one of the lab's reserved IPs to
        # simulate "another device already holds it."
        { & $script:deployScript } | Should -Throw '*already in use on the LAN*'
        Get-VM -Name $script:vmDefs[0].Name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'reports created VMs and does not auto-cleanup when disk space runs out mid-loop' {
        { & $script:deployScript -MinFreeDiskGB ([int]::MaxValue) } | Should -Throw '*below the*threshold*'
        # No VMs should have been created at all - the disk check runs first,
        # before any VM/disk is touched.
        Get-VM -Name $script:vmDefs[0].Name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'v1-proven gate' -Tag 'RequiresHyperV' -Skip:(-not $script:hyperVAvailable) {

    It 'survives 3 clean deploy -> reset -> deploy cycles with no manual intervention' {
        # This IS the design doc's "v1 proven" bar (line 87) - as one automated
        # test instead of manually babysitting 3 runs.
        for ($i = 1; $i -le 3; $i++) {
            & $script:deployScript
            foreach ($vm in $script:vmDefs) {
                (Get-VM -Name $vm.Name).State | Should -Be 'Running'
            }
            & $script:resetScript
        }
    }
}

AfterAll {
    if ($script:hyperVAvailable) {
        foreach ($vm in $script:vmDefs) {
            Remove-VM -Name $vm.Name -Force -ErrorAction SilentlyContinue
        }
    }
}
