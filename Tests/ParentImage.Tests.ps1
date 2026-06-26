#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Lib/ParentImage.psm1 (test-review diagram: Protect-ParentImage
    sets+verifies read-only, errors clearly on a bad path).
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Lib\ParentImage.psm1') -Force
}

Describe 'Get-ParentImagePath (root+filename fallback)' {
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

Describe 'Set-ParentImagePath' {
    BeforeEach {
        # Re-import to reset $Script:ParentImagePathOverrides to @{} between tests.
        # Without this, an override set in one test would bleed into the next.
        Import-Module (Join-Path $PSScriptRoot '..\Lib\ParentImage.psm1') -Force
    }

    It 'causes Get-ParentImagePath to return the override path for the specified OS image' {
        $customPath = 'D:\Templates\MyServer.vhdx'
        Set-ParentImagePath -OSImage 'Server2022' -Path $customPath
        Get-ParentImagePath -OSImage 'Server2022' | Should -Be $customPath
    }

    It 'override is scoped to the specified OS image — other images still resolve via root+filename' {
        Set-ParentImagePath -OSImage 'Server2022' -Path 'D:\Templates\MyServer.vhdx'
        $client11Path = Get-ParentImagePath -OSImage 'Client11'
        $client11Path | Should -Not -Be 'D:\Templates\MyServer.vhdx'
        $client11Path | Should -Match 'Client11'
    }

    It 'a second Set-ParentImagePath call for the same OS image replaces the first override' {
        Set-ParentImagePath -OSImage 'Server2022' -Path 'D:\Templates\v1.vhdx'
        Set-ParentImagePath -OSImage 'Server2022' -Path 'D:\Templates\v2.vhdx'
        Get-ParentImagePath -OSImage 'Server2022' | Should -Be 'D:\Templates\v2.vhdx'
    }

    It 'multiple OS images can each carry an independent override simultaneously' {
        Set-ParentImagePath -OSImage 'Server2022' -Path 'D:\Templates\SrvTemplate.vhdx'
        Set-ParentImagePath -OSImage 'Client11'   -Path 'D:\Templates\Cl11Template.vhdx'
        Get-ParentImagePath -OSImage 'Server2022' | Should -Be 'D:\Templates\SrvTemplate.vhdx'
        Get-ParentImagePath -OSImage 'Client11'   | Should -Be 'D:\Templates\Cl11Template.vhdx'
    }

    It 'override path is returned verbatim — no normalization or existence check' {
        $arbitraryPath = 'X:\Totally\Different\Path\MySrv.vhdx'
        Set-ParentImagePath -OSImage 'Server2022' -Path $arbitraryPath
        Get-ParentImagePath -OSImage 'Server2022' | Should -Be $arbitraryPath
    }

    It 'without a prior override, Get-ParentImagePath still falls back to root+filename' {
        $path = Get-ParentImagePath -OSImage 'Server2022'
        $path | Should -Match 'Server2022'
        $path | Should -Match 'Base'
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
