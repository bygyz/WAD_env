#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Lib/OneDriveDownload.psm1.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Lib\OneDriveDownload.psm1') -Force
}

Describe 'Invoke-OneDriveDownload' {
    BeforeEach {
        # Stub the internal HTTP layer so no real network calls are made.
        Mock Invoke-HttpGet {} -ModuleName OneDriveDownload
    }

    It 'passes the correctly encoded OneDrive API URL to the HTTP layer' {
        $capturedUrl = $null
        Mock Invoke-HttpGet { $capturedUrl = $Url } -ModuleName OneDriveDownload

        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!ABC123xyz' `
            -DestinationPath (Join-Path $TestDrive 'out.vhdx')

        $capturedUrl | Should -Match '^https://api\.onedrive\.com/v1\.0/shares/u!'
        $capturedUrl | Should -Match '/root/content$'
        # URL-safe base64 must not contain padding chars or standard +/ chars
        $capturedUrl | Should -Not -Match '='
        $capturedUrl | Should -Not -Match '\+'
    }

    It 'passes the destination path to the HTTP layer unchanged' {
        $capturedDest = $null
        Mock Invoke-HttpGet { $capturedDest = $DestinationPath } -ModuleName OneDriveDownload

        $dest = Join-Path $TestDrive 'Server2022-Base.vhdx'
        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' -DestinationPath $dest

        $capturedDest | Should -Be $dest
    }

    It 'creates the destination directory if it does not exist' {
        $dest = Join-Path $TestDrive 'NewDir\SubDir\image.vhdx'
        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' -DestinationPath $dest
        Test-Path -LiteralPath (Split-Path $dest -Parent) | Should -BeTrue
    }

    It 'does not throw when the destination directory already exists' {
        $existingDir = Join-Path $TestDrive 'Existing'
        New-Item -ItemType Directory -Path $existingDir | Out-Null
        { Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' `
              -DestinationPath (Join-Path $existingDir 'image.vhdx') } | Should -Not -Throw
    }

    It 'propagates a download error without swallowing it' {
        Mock Invoke-HttpGet { throw 'connection refused' } -ModuleName OneDriveDownload
        { Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' `
              -DestinationPath (Join-Path $TestDrive 'out.vhdx') } | Should -Throw '*connection refused*'
    }

    It 'two different sharing URLs produce two different API URLs' {
        $captured = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-HttpGet { $captured.Add($Url) } -ModuleName OneDriveDownload

        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!AAAA' -DestinationPath (Join-Path $TestDrive 'a.vhdx')
        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!BBBB' -DestinationPath (Join-Path $TestDrive 'b.vhdx')

        $captured[0] | Should -Not -Be $captured[1]
    }
}
