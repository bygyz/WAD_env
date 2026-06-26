#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Lib/DiskBudget.psm1 (Outside Voice Issue 11: pre-flight
    threshold check + post-reset size reporting).
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Lib\DiskBudget.psm1') -Force
}

Describe 'Assert-LabDiskSpace' {
    It 'does not throw when free space is above the threshold' {
        { Assert-LabDiskSpace -Path $TestDrive -MinFreeGB 0 } | Should -Not -Throw
    }

    It 'throws a clear error when free space is below the threshold' {
        # [int]::MaxValue GB is already far more than any real disk - and,
        # unlike [double]::MaxValue/1GB, it actually fits in the function's
        # [int] parameter instead of failing at parameter-binding first
        # (confirmed by running this: that's exactly what happened).
        { Assert-LabDiskSpace -Path $TestDrive -MinFreeGB ([int]::MaxValue) } | Should -Throw '*below the*threshold*'
    }

    It 'walks up to an existing ancestor when the exact path does not exist yet' {
        $notYetCreated = Join-Path $TestDrive 'VMs\does-not-exist-yet'
        { Assert-LabDiskSpace -Path $notYetCreated -MinFreeGB 0 } | Should -Not -Throw
    }
}

Describe 'Get-LabDifferencingDiskSizes' {
    It 'returns an empty array when the storage root does not exist' {
        $missingRoot = Join-Path $TestDrive 'NeverCreated'
        @(Get-LabDifferencingDiskSizes -VmStorageRoot $missingRoot).Count | Should -Be 0
    }

    It 'reports size for every .vhdx and .avhdx file found' {
        # Dedicated, freshly-cleaned subfolder - not the generic 'VMs' name
        # other tests/Describes also reference under the same shared
        # $TestDrive, to rule out any cross-test file collision.
        $root = Join-Path $TestDrive 'DiskSizeTest-VMs'
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
        New-Item -ItemType Directory -Path (Join-Path $root 'DC1') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'DC1\DC1.vhdx') -Value ('x' * 1024)
        Set-Content -LiteralPath (Join-Path $root 'DC1\DC1_checkpoint.avhdx') -Value ('x' * 2048)
        Set-Content -LiteralPath (Join-Path $root 'DC1\notes.txt') -Value 'irrelevant file'

        $sizes = Get-LabDifferencingDiskSizes -VmStorageRoot $root
        $sizes.Count | Should -Be 2
        ($sizes.Path | Sort-Object) | Should -Be (
            (Join-Path $root 'DC1\DC1.vhdx'), (Join-Path $root 'DC1\DC1_checkpoint.avhdx') | Sort-Object
        )
    }
}
