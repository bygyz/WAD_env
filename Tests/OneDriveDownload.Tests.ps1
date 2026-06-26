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
        Mock Invoke-HttpGet {} -ModuleName OneDriveDownload
    }

    Context 'Personal OneDrive URLs (1drv.ms / onedrive.live.com)' {
        It 'builds an api.onedrive.com base64url API URL' {
            $capturedUrl = $null
            Mock Invoke-HttpGet { $capturedUrl = $Url } -ModuleName OneDriveDownload

            Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!ABC123xyz' `
                -DestinationPath (Join-Path $TestDrive 'out.vhdx')

            $capturedUrl | Should -Match '^https://api\.onedrive\.com/v1\.0/shares/u!'
            $capturedUrl | Should -Match '/root/content$'
            $capturedUrl | Should -Not -Match '='   # no base64 padding
            $capturedUrl | Should -Not -Match '\+'  # no standard base64 chars
        }

        It 'two different sharing URLs produce two different encoded API URLs' {
            $captured = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-HttpGet { $captured.Add($Url) } -ModuleName OneDriveDownload

            Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!AAAA' -DestinationPath (Join-Path $TestDrive 'a.vhdx')
            Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!BBBB' -DestinationPath (Join-Path $TestDrive 'b.vhdx')

            $captured[0] | Should -Not -Be $captured[1]
        }
    }

    Context 'SharePoint / OneDrive for Business URLs (*.sharepoint.com)' {
        It 'appends &download=1 when the URL already has a query string' {
            $capturedUrl = $null
            Mock Invoke-HttpGet { $capturedUrl = $Url } -ModuleName OneDriveDownload

            Invoke-OneDriveDownload `
                -SharingUrl 'https://contoso-my.sharepoint.com/:u:/g/personal/user/FileId?e=ABC123' `
                -DestinationPath (Join-Path $TestDrive 'out.vhdx')

            $capturedUrl | Should -Match '&download=1$'
            $capturedUrl | Should -Not -Match 'api\.onedrive\.com'
        }

        It 'appends ?download=1 when the URL has no query string' {
            $capturedUrl = $null
            Mock Invoke-HttpGet { $capturedUrl = $Url } -ModuleName OneDriveDownload

            Invoke-OneDriveDownload `
                -SharingUrl 'https://contoso-my.sharepoint.com/:u:/g/personal/user/FileId' `
                -DestinationPath (Join-Path $TestDrive 'out.vhdx')

            $capturedUrl | Should -Match '\?download=1$'
        }
    }

    Context 'Common behaviour (both URL types)' {
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
    }
}
