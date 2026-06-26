#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Lib/OneDriveDownload.psm1.
#>

BeforeAll {
    function Start-BitsTransfer { param($Source, $Destination, $DisplayName) }
    Import-Module (Join-Path $PSScriptRoot '..\Lib\OneDriveDownload.psm1') -Force
}

Describe 'Invoke-OneDriveDownload' {
    BeforeEach {
        # Stub both internal steps so no real network calls are made.
        Mock Resolve-HttpRedirect { return 'https://cdn.example.com/fake-download' } -ModuleName OneDriveDownload
        Mock Start-BitsTransfer {} -ModuleName OneDriveDownload
    }

    It 'passes the correctly encoded OneDrive API URL to the redirect resolver' {
        $capturedUrl = $null
        Mock Resolve-HttpRedirect { $capturedUrl = $Url; return 'https://cdn.example.com/fake' } -ModuleName OneDriveDownload

        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!ABC123xyz' `
            -DestinationPath (Join-Path $TestDrive 'out.vhdx')

        $capturedUrl | Should -Match '^https://api\.onedrive\.com/v1\.0/shares/u!'
        $capturedUrl | Should -Match '/root/content$'
        # URL-safe base64 must not contain padding or the standard +/ chars
        $capturedUrl | Should -Not -Match '='
        $capturedUrl | Should -Not -Match '\+'
    }

    It 'passes the resolved CDN URL (not the API URL) to Start-BitsTransfer' {
        $fakeCdnUrl = 'https://cdn.example.com/resolved-file.vhdx'
        Mock Resolve-HttpRedirect { return $fakeCdnUrl } -ModuleName OneDriveDownload
        $capturedSource = $null
        Mock Start-BitsTransfer { $capturedSource = $Source } -ModuleName OneDriveDownload

        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' `
            -DestinationPath (Join-Path $TestDrive 'out.vhdx')

        $capturedSource | Should -Be $fakeCdnUrl
    }

    It 'passes the destination path to Start-BitsTransfer unchanged' {
        $capturedDest = $null
        Mock Start-BitsTransfer { $capturedDest = $Destination } -ModuleName OneDriveDownload

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

    It 'propagates an error from Start-BitsTransfer without swallowing it' {
        Mock Start-BitsTransfer { throw 'network error' } -ModuleName OneDriveDownload
        { Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' `
              -DestinationPath (Join-Path $TestDrive 'out.vhdx') } | Should -Throw '*network error*'
    }

    It 'propagates an error from redirect resolution without swallowing it' {
        Mock Resolve-HttpRedirect { throw 'connection refused' } -ModuleName OneDriveDownload
        { Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' `
              -DestinationPath (Join-Path $TestDrive 'out.vhdx') } | Should -Throw '*connection refused*'
    }

    It 'two different sharing URLs produce two different API URLs sent to the resolver' {
        $captured = [System.Collections.Generic.List[string]]::new()
        Mock Resolve-HttpRedirect { $captured.Add($Url); return 'https://cdn.example.com/fake' } -ModuleName OneDriveDownload

        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!AAAA' -DestinationPath (Join-Path $TestDrive 'a.vhdx')
        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!BBBB' -DestinationPath (Join-Path $TestDrive 'b.vhdx')

        $captured[0] | Should -Not -Be $captured[1]
    }
}
