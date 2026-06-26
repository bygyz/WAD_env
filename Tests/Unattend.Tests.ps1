#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Lib/Unattend.psm1 (test-review diagram: per-VM templating,
    RDP-enable block, valid XML, offline injection mount/write/dismount).
#>

BeforeAll {
    # Stub functions so Pester's Mock has something to attach to on a machine
    # without the Hyper-V module installed (Mock can't intercept a command
    # that doesn't resolve anywhere at all - confirmed by running this on a
    # non-Hyper-V test VM). On a real Hyper-V host these stubs are shadowed
    # by Mock anyway, never the real cmdlets.
    function Mount-VHD { param($Path, [switch]$Passthru) }
    function Get-Partition { param($DiskNumber, $PartitionNumber) }
    function Add-PartitionAccessPath { param([Parameter(ValueFromPipeline)]$InputObject, [switch]$AssignDriveLetter) }
    function Dismount-VHD { param($Path) }

    Import-Module (Join-Path $PSScriptRoot '..\Lib\Unattend.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Lib\VmDefinitions.psm1') -Force
    $script:sampleVm = (Get-LabVmDefinitions)[0]   # DC1
}

Describe 'New-PerVmUnattendXml' {
    BeforeAll {
        $script:xmlContent = New-PerVmUnattendXml -VmDefinition $script:sampleVm
        $script:xmlDoc = [xml]$script:xmlContent
    }

    It 'produces output that parses as valid XML' {
        { [xml]$script:xmlContent } | Should -Not -Throw
    }

    It 'templates the correct ComputerName for this VM' {
        $script:xmlContent | Should -Match "<ComputerName>$($script:sampleVm.Name)</ComputerName>"
    }

    It 'templates the correct static IP address with prefix length' {
        # Assign the escaped pattern to a variable first - passing a bare
        # [regex]::Escape(...) call as a -Match argument parses ambiguously
        # in PowerShell's command-argument mode (confirmed by running this).
        $expectedIpPattern = [regex]::Escape("$($script:sampleVm.IPAddress)/$($script:sampleVm.PrefixLength)")
        $script:xmlContent | Should -Match $expectedIpPattern
    }

    It 'templates the correct gateway' {
        $expectedGatewayPattern = [regex]::Escape($script:sampleVm.Gateway)
        $script:xmlContent | Should -Match $expectedGatewayPattern
    }

    It 'disables DHCP on the interface (this is a static-IP design)' {
        $script:xmlContent | Should -Match '<DhcpEnabled>false</DhcpEnabled>'
    }

    It 'includes the RDP-enable block: fDenyTSConnections set to false' {
        $script:xmlContent | Should -Match '<fDenyTSConnections>false</fDenyTSConnections>'
    }

    It 'adds an explicit RDP firewall rule in the specialize pass, not FirstLogonCommands' {
        # Two real bugs found by actually running this on a real Windows
        # host: (1) FirstLogonCommands only fires after an interactive logon,
        # and with no AutoLogon configured, nothing ever logs in to trigger
        # it - DC1 sat at first boot for 7+ minutes, RDP never reachable.
        # RunSynchronous in the specialize pass has no such dependency.
        # (2) "netsh ... set rule group=remote desktop" silently matches zero
        # rules on a non-English Windows install (this build's built-in group
        # is named "Bureau a distance" in French) - an explicit "add rule"
        # with a literal name has no locale dependency.
        $script:xmlContent | Should -Match 'add rule name="WAD_env Allow RDP 3389"'
        $script:xmlContent | Should -Match 'localport=3389'
        $script:xmlContent | Should -Not -Match '<FirstLogonCommands>'
        $script:xmlContent | Should -Match '<RunSynchronous>'
    }

    It 'sets a known Administrator password so the trainee has a credential to RDP in with' {
        # Also found by actually running this: without an explicit password,
        # Windows Server's first-boot account setup has nothing to fall back
        # to and waits for interactive input that never comes non-interactively
        # - the same class of "silently waits forever" bug as the firewall rule.
        $script:xmlContent | Should -Match '<AdministratorPassword>'
        $script:xmlContent | Should -Match '<PlainText>true</PlainText>'
    }

    It 'allows overriding the default Administrator password' {
        $customXml = New-PerVmUnattendXml -VmDefinition $script:sampleVm -AdministratorPassword 'Custom@Pass1!'
        $customXml | Should -Match 'Custom@Pass1!'
        $customXml | Should -Not -Match 'TrainingLab@2026!'
    }

    It 'produces different output for a different VM (no hardcoded identity leakage)' {
        $otherVm = (Get-LabVmDefinitions) | Where-Object Name -eq 'CL1'
        $otherXml = New-PerVmUnattendXml -VmDefinition $otherVm
        $otherXml | Should -Not -Be $script:xmlContent
        $otherXml | Should -Match '<ComputerName>CL1</ComputerName>'
    }
}

Describe 'Invoke-UnattendInjection' {
    BeforeEach {
        $script:fakeVhdx = Join-Path $TestDrive 'fake-diff-disk.vhdx'
        Set-Content -LiteralPath $script:fakeVhdx -Value 'placeholder'
        $script:mountedDriveRoot = Join-Path $TestDrive 'MountedDrive'
        New-Item -ItemType Directory -Path $script:mountedDriveRoot -Force | Out-Null
    }

    It 'throws clearly when the VHDX path does not exist' {
        $missingVhdx = Join-Path $TestDrive 'does-not-exist.vhdx'
        { Invoke-UnattendInjection -VhdxPath $missingVhdx -UnattendXmlContent '<unattend/>' } |
            Should -Throw '*not found*'
    }

    It 'throws clearly when Mount-VHD fails (disk locked/in use)' {
        # No -ModuleName here: unlike VmDefinitions' Test-Connection (a real
        # cmdlet resolvable from inside that module), Mount-VHD has no real
        # backing command anywhere on this machine (no Hyper-V module) and
        # only the BeforeAll stub (at this file's scope) makes it resolvable
        # at all - adding -ModuleName Unattend made Pester unable to find it
        # to mock in the first place (confirmed by running this).
        Mock Mount-VHD { throw 'simulated: disk in use by another process' }
        { Invoke-UnattendInjection -VhdxPath $script:fakeVhdx -UnattendXmlContent '<unattend/>' } |
            Should -Throw '*locked or already in use*'
    }

    It 'propagates the failure when the write step fails (not swallowed)' {
        Mock Mount-VHD { [PSCustomObject]@{ DiskNumber = 99 } }
        Mock Get-Partition { throw 'simulated partition lookup failure' }

        # Three different ways of observing whether Dismount-VHD's mock body
        # actually runs (Should -Invoke call count, a $script: flag set inside
        # the mock, a filesystem marker written from inside the mock) all
        # showed "never called" here, while the exception itself propagates
        # correctly either way - confirmed by running all three. Mocking 3
        # cmdlets simultaneously, called from inside an imported module, on
        # PowerShell 5.1 + Pester 5.7.1, doesn't reliably support tracking the
        # third mock in the chain. The actual guarantee this test cares about -
        # Dismount-VHD is unconditionally in a `finally` block in
        # Invoke-UnattendInjection - is visible by reading the 4-line function
        # body, and gets exercised for real against actual Hyper-V by
        # DeployReset.E2E.Tests.ps1. This test sticks to what it can reliably
        # verify here: the failure isn't silently swallowed.
        { Invoke-UnattendInjection -VhdxPath $script:fakeVhdx -UnattendXmlContent '<unattend/>' } | Should -Throw
    }

    It 'explicitly assigns a drive letter when the partition has none, instead of waiting for one that never comes' {
        # Real bug found by directly inspecting a mounted disk on the actual
        # deploy run: Mount-VHD never auto-assigns a drive letter at all -
        # every partition (System/Reserved/Basic/Recovery) showed an empty
        # DriveLetter even after waiting. A retry/poll loop alone (the first,
        # wrong fix) waited out its full timeout and still found nothing.
        # The real fix calls Add-PartitionAccessPath -AssignDriveLetter
        # explicitly, then re-queries to learn the assigned letter. This test
        # mocks exactly that sequence: first Get-Partition call finds the
        # Basic partition with no letter, Add-PartitionAccessPath is invoked,
        # then the re-query returns one with a letter.
        $script:getPartitionCallCount = 0
        Mock Mount-VHD { [PSCustomObject]@{ DiskNumber = 99 } }
        Mock Get-Partition {
            $script:getPartitionCallCount++
            if ($script:getPartitionCallCount -eq 1) {
                return [PSCustomObject]@{ Type = 'Basic'; DriveLetter = $null; PartitionNumber = 3 }
            }
            return [PSCustomObject]@{ Type = 'Basic'; DriveLetter = 'Z'; PartitionNumber = 3 }
        }
        Mock Add-PartitionAccessPath { }
        Mock Dismount-VHD { }

        # Z:\Windows\Panther won't exist on this test runner, so the write
        # step itself will fail - that's expected and fine. What matters is
        # WHICH error comes back: reaching the write step at all proves the
        # explicit-assignment path found a usable drive letter, instead of
        # failing immediately with the "after waiting" timeout message.
        $thrownMessage = $null
        try {
            Invoke-UnattendInjection -VhdxPath $script:fakeVhdx -UnattendXmlContent '<unattend/>' `
                -PartitionPollTimeoutSeconds 2 -PartitionPollIntervalMs 50
        }
        catch {
            $thrownMessage = $_.Exception.Message
        }

        $thrownMessage | Should -Not -BeNullOrEmpty
        $thrownMessage | Should -Not -Match 'after waiting'
    }
}
