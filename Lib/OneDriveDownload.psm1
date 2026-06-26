#Requires -Version 5.1

Set-StrictMode -Version Latest

function Invoke-OneDriveDownload {
    <#
    .SYNOPSIS
        Downloads a file from a personal OneDrive sharing link using BITS.
    .DESCRIPTION
        Converts a personal OneDrive sharing URL (https://1drv.ms/...) to a
        direct download URL via the OneDrive API's base64url share encoding,
        then transfers the file using Start-BitsTransfer. BITS follows the
        redirect from the API URL to the real CDN URL automatically, shows
        transfer progress in the console, and handles large files (15-20 GB)
        reliably without holding the whole file in memory.

        The destination directory is created automatically if it doesn't exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SharingUrl,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($SharingUrl)
    $b64    = [Convert]::ToBase64String($bytes)
    $b64url = 'u!' + $b64.TrimEnd('=').Replace('/', '_').Replace('+', '-')
    $dlUrl  = "https://api.onedrive.com/v1.0/shares/$b64url/root/content"

    $dir = Split-Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Start-BitsTransfer -Source $dlUrl -Destination $DestinationPath `
        -DisplayName "Downloading $(Split-Path $DestinationPath -Leaf)"
}

Export-ModuleMember -Function Invoke-OneDriveDownload
