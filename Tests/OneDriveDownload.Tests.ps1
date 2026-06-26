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

    It 'converts the sharing URL to the OneDrive API base64url download URL' {
        $capturedSource = $null
        Mock Start-BitsTransfer { $capturedSource = $Source } -ModuleName OneDriveDownload

        $sharingUrl = 'https://1drv.ms/u/s!ABC123xyz'
        Invoke-OneDriveDownload -SharingUrl $sharingUrl -DestinationPath (Join-Path $TestDrive 'out.vhdx')

        $capturedSource | Should -Match '^https://api\.onedrive\.com/v1\.0/shares/u!'
        $capturedSource | Should -Match '/root/content$'
        # The encoded segment must not contain raw base64 padding or '/' or '+'
        $capturedSource | Should -Not -Match '='
        $capturedSource | Should -Not -Match '\+'
    }

    It 'passes the destination path to Start-BitsTransfer unchanged' {
        $capturedDest = $null
        Mock Start-BitsTransfer { $capturedDest = $Destination } -ModuleName OneDriveDownload

        $dest = Join-Path $TestDrive 'Server2022-Base.vhdx'
        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' -DestinationPath $dest

        $capturedDest | Should -Be $dest
    }

    It 'creates the destination directory if it does not exist' {
        Mock Start-BitsTransfer {} -ModuleName OneDriveDownload

        $dest = Join-Path $TestDrive 'NewDir\SubDir\image.vhdx'
        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' -DestinationPath $dest

        Test-Path -LiteralPath (Split-Path $dest -Parent) | Should -BeTrue
    }

    It 'does not create the directory if it already exists' {
        Mock Start-BitsTransfer {} -ModuleName OneDriveDownload

        $existingDir = Join-Path $TestDrive 'Existing'
        New-Item -ItemType Directory -Path $existingDir | Out-Null
        $dest = Join-Path $existingDir 'image.vhdx'

        { Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' -DestinationPath $dest } | Should -Not -Throw
    }

    It 'propagates an error from Start-BitsTransfer without swallowing it' {
        Mock Start-BitsTransfer { throw 'network error' } -ModuleName OneDriveDownload

        { Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!XYZ' `
              -DestinationPath (Join-Path $TestDrive 'out.vhdx') } | Should -Throw '*network error*'
    }

    It 'two different sharing URLs produce two different encoded download URLs' {
        $captured = [System.Collections.Generic.List[string]]::new()
        Mock Start-BitsTransfer { $captured.Add($Source) } -ModuleName OneDriveDownload

        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!AAAA' -DestinationPath (Join-Path $TestDrive 'a.vhdx')
        Invoke-OneDriveDownload -SharingUrl 'https://1drv.ms/u/s!BBBB' -DestinationPath (Join-Path $TestDrive 'b.vhdx')

        $captured[0] | Should -Not -Be $captured[1]
    }
}
