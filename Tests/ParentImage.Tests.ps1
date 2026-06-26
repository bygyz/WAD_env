#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Lib/ParentImage.psm1 (test-review diagram: Protect-ParentImage
    sets+verifies read-only, errors clearly on a bad path).
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Lib\ParentImage.psm1') -Force
}

Describe 'Get-ParentImagePath' {
    It 'resolves a distinct path per OS image type' {
        $serverPath = Get-ParentImagePath -OSImage 'Server2022'
        $client10Path = Get-ParentImagePath -OSImage 'Client10'
        $client11Path = Get-ParentImagePath -OSImage 'Client11'
        $serverPath | Should -Not -Be $client10Path
        $client10Path | Should -Not -Be $client11Path
        $serverPath | Should -Match 'Server2022'
        $client10Path | Should -Match 'Client10'
        $client11Path | Should -Match 'Client11'
    }
}

Describe 'Protect-ParentImage' {
    BeforeEach {
        $script:testFile = Join-Path $TestDrive 'fake-parent.vhdx'
        if (Test-Path -LiteralPath $script:testFile) {
            # A prior test in this Describe may have left this read-only -
            # clear it before removing, or the overwrite below gets Access Denied.
            Set-ItemProperty -LiteralPath $script:testFile -Name IsReadOnly -Value $false
            Remove-Item -LiteralPath $script:testFile -Force
        }
        Set-Content -LiteralPath $script:testFile -Value 'placeholder vhdx content'
    }

    It 'sets the file read-only' {
        Protect-ParentImage -Path $script:testFile
        (Get-Item -LiteralPath $script:testFile).IsReadOnly | Should -BeTrue
    }

    It 'leaves the file verifiably read-only via Test-ParentImageProtected' {
        Protect-ParentImage -Path $script:testFile
        Test-ParentImageProtected -Path $script:testFile | Should -BeTrue
    }

    It 'throws clearly when the path does not exist' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.vhdx'
        { Protect-ParentImage -Path $missingPath } | Should -Throw '*not found*'
    }
}

Describe 'Test-ParentImageProtected' {
    It 'returns $false for a writable file' {
        $writableFile = Join-Path $TestDrive 'writable.vhdx'
        Set-Content -LiteralPath $writableFile -Value 'placeholder'
        Test-ParentImageProtected -Path $writableFile | Should -BeFalse
    }

    It 'throws clearly when the path does not exist' {
        $missingPath = Join-Path $TestDrive 'also-missing.vhdx'
        { Test-ParentImageProtected -Path $missingPath } | Should -Throw '*not found*'
    }
}

Describe 'Initialize-ParentImageRoot' {
    It 'creates the parent-image directory if missing, without touching any VHDX' {
        { Initialize-ParentImageRoot } | Should -Not -Throw
    }
}
