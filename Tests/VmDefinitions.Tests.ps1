#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Lib/VmDefinitions.psm1 (test-review diagram rows: defs +
    Test-IPAvailable true/false branches).
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Lib\VmDefinitions.psm1') -Force
}

Describe 'Get-LabVmDefinitions' {
    BeforeAll {
        $script:defs = Get-LabVmDefinitions
    }

    It 'returns exactly 5 VM definitions by default (2 Domain A DCs, 1 Domain B DC, 2 clients)' {
        $script:defs.Count | Should -Be 5
    }

    It 'returns the default-count hostnames DC1, DC2, PDC1, CL1, CL2' {
        ($script:defs.Name | Sort-Object) | Should -Be @('CL1', 'CL2', 'DC1', 'DC2', 'PDC1')
    }

    It 'assigns DC1 and DC2 to Domain A (corp.lab)' {
        ($script:defs | Where-Object Name -in 'DC1', 'DC2').Domain | Should -Be @('corp.lab', 'corp.lab')
    }

    It 'assigns PDC1 to the separate Domain B (partner.lab)' {
        ($script:defs | Where-Object Name -eq 'PDC1').Domain | Should -Be 'partner.lab'
    }

    It 'assigns both clients to Domain A' {
        ($script:defs | Where-Object Name -in 'CL1', 'CL2').Domain | Should -Be @('corp.lab', 'corp.lab')
    }

    It 'marks all 3 DCs with OSImage Server2022' {
        ($script:defs | Where-Object Role -eq 'DomainController').OSImage | Should -Be @('Server2022', 'Server2022', 'Server2022')
    }

    It 'marks both clients with OSImage Client11 (Client10 template is unusable on this host for now)' {
        ($script:defs | Where-Object Role -eq 'Client').OSImage | Should -Be @('Client11', 'Client11')
    }

    It 'marks exactly one DC per domain as IsFirstDC (the forest creator)' {
        ($script:defs | Where-Object { $_.IsFirstDC -and $_.Domain -eq 'corp.lab' }).Name | Should -Be 'DC1'
        ($script:defs | Where-Object { $_.IsFirstDC -and $_.Domain -eq 'partner.lab' }).Name | Should -Be 'PDC1'
    }

    It 'assigns 5 distinct, non-empty, sequential IP addresses' {
        $ips = $script:defs.IPAddress
        ($ips | Sort-Object -Unique).Count | Should -Be 5
        $ips | ForEach-Object { $_ | Should -Match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
        $lastOctets = $ips | ForEach-Object { [int]($_ -split '\.')[3] } | Sort-Object
        ($lastOctets[-1] - $lastOctets[0]) | Should -Be 4
    }

    It 'accepts an overridden NetworkConfig' {
        $customConfig = [PSCustomObject]@{
            SubnetPrefixLength = 24
            Gateway            = '10.0.5.1'
            DnsServers         = @('10.0.5.1')
            BaseIPAddress      = '10.0.5.11'
        }
        $overridden = Get-LabVmDefinitions -NetworkConfig $customConfig
        ($overridden | Where-Object Name -eq 'DC1').IPAddress | Should -Be '10.0.5.11'
        ($overridden | Where-Object Name -eq 'DC1').Gateway | Should -Be '10.0.5.1'
    }

    It 'renames a VM via NameOverrides while keeping its domain/IP/OS assignment intact' {
        $renamed = Get-LabVmDefinitions -NameOverrides @{ DC1 = 'TRAINER-DC01' }
        ($renamed | Where-Object Name -eq 'TRAINER-DC01') | Should -Not -BeNullOrEmpty
        ($renamed | Where-Object Name -eq 'TRAINER-DC01').Domain | Should -Be 'corp.lab'
        ($renamed | Where-Object Name -eq 'TRAINER-DC01').IPAddress | Should -Be $script:defs[0].IPAddress
        ($renamed | Where-Object Name -eq 'DC1') | Should -BeNullOrEmpty
    }

    It 'leaves every other VM unrenamed when only one NameOverrides entry is given' {
        $renamed = Get-LabVmDefinitions -NameOverrides @{ DC1 = 'TRAINER-DC01' }
        ($renamed.Name | Sort-Object) | Should -Be @('CL1', 'CL2', 'DC2', 'PDC1', 'TRAINER-DC01')
    }

    It 'overrides one VM''s IP via IPOverrides while leaving the rest on their sequential allocation' {
        $overridden = Get-LabVmDefinitions -IPOverrides @{ DC2 = '192.168.1.99' }
        ($overridden | Where-Object Name -eq 'DC2').IPAddress | Should -Be '192.168.1.99'
        ($overridden | Where-Object Name -eq 'DC1').IPAddress | Should -Be $script:defs[0].IPAddress
    }

    It 'resolves NameOverrides and IPOverrides independently when both target the same VM' {
        $both = Get-LabVmDefinitions -NameOverrides @{ DC1 = 'TRAINER-DC01' } -IPOverrides @{ DC1 = '192.168.1.50' }
        ($both | Where-Object Name -eq 'TRAINER-DC01').IPAddress | Should -Be '192.168.1.50'
    }

    It 'scales VM counts per role independently' {
        $scaled = Get-LabVmDefinitions -DomainAServerCount 3 -DomainBServerCount 2 -ClientCount 1
        $scaled.Count | Should -Be 6
        ($scaled | Where-Object Domain -eq 'corp.lab' | Where-Object Role -eq 'DomainController').Name | Should -Be @('DC1', 'DC2', 'DC3')
        ($scaled | Where-Object Domain -eq 'partner.lab').Name | Should -Be @('PDC1', 'PDC2')
        ($scaled | Where-Object Role -eq 'Client').Name | Should -Be @('CL1')
    }

    It 'skips Domain B entirely when DomainBServerCount is 0' {
        $noTrust = Get-LabVmDefinitions -DomainBServerCount 0
        $noTrust.Count | Should -Be 4
        ($noTrust | Where-Object Domain -eq 'partner.lab') | Should -BeNullOrEmpty
    }

    It 'throws a clear error when the requested count would run the IP block past .255' {
        { Get-LabVmDefinitions -DomainAServerCount 99 -DomainBServerCount 99 -ClientCount 99 } | Should -Throw '*past .255*'
    }
}

Describe 'Test-IPAvailable' {
    # -ModuleName is required: Test-IPAvailable calls Test-Connection from
    # INSIDE the VmDefinitions module, so without -ModuleName the mock only
    # applies to this test file's own scope and the REAL Test-Connection runs
    # instead (confirmed by running this - the "mocked" calls took ~3s, real
    # ICMP timing, not an instant mocked return).
    Context 'when the address responds to ping (already in use)' {
        It 'returns $false' {
            Mock Test-Connection { return $true } -ModuleName VmDefinitions
            Test-IPAvailable -IPAddress '192.168.1.241' | Should -BeFalse
        }
    }

    Context 'when the address does not respond (free)' {
        It 'returns $true' {
            Mock Test-Connection { return $false } -ModuleName VmDefinitions
            Test-IPAvailable -IPAddress '192.168.1.241' | Should -BeTrue
        }
    }

    Context 'when Test-Connection itself errors' {
        It 'throws rather than assuming the IP is free' {
            Mock Test-Connection { throw 'simulated ICMP permission failure' } -ModuleName VmDefinitions
            { Test-IPAvailable -IPAddress '192.168.1.241' } | Should -Throw
        }
    }
}

Describe 'Test-LabIPBlockAvailable' {
    BeforeAll {
        $script:defs = Get-LabVmDefinitions
    }

    It 'passes silently when every IP is free' {
        Mock Test-Connection { return $false } -ModuleName VmDefinitions
        { Test-LabIPBlockAvailable -VmDefinitions $script:defs } | Should -Not -Throw
    }

    It 'throws and names every conflicting IP when one or more are taken' {
        Mock Test-Connection {
            param($ComputerName)
            return ($ComputerName -eq $script:defs[0].IPAddress)
        } -ModuleName VmDefinitions
        { Test-LabIPBlockAvailable -VmDefinitions $script:defs } | Should -Throw "*$($script:defs[0].Name)*$($script:defs[0].IPAddress)*"
    }
}
