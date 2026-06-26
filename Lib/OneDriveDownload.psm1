#Requires -Version 5.1

Set-StrictMode -Version Latest

function Resolve-HttpRedirect {
    # BITS does not follow HTTP redirects on its own — confirmed: the OneDrive
    # API URL (/shares/u!.../root/content) returns a 302 to the real CDN URL,
    # and BITS stops there with "HTTP redirect required". Resolve the full
    # redirect chain with a HEAD request first, then hand the final URL to BITS.
    param([Parameter(Mandatory)][string]$Url)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'HEAD'
    $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    $finalUrl = $resp.ResponseUri.AbsoluteUri
    $resp.Close()
    return $finalUrl
}

function Invoke-OneDriveDownload {
    <#
    .SYNOPSIS
        Downloads a file from a personal OneDrive sharing link using BITS.
    .DESCRIPTION
        Converts a personal OneDrive sharing URL (https://1drv.ms/...) to the
        OneDrive API base64url URL, resolves the redirect chain to the real CDN
        URL, then transfers the file using Start-BitsTransfer. BITS shows
        transfer progress in the console and handles large files (15-20 GB)
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
    $apiUrl = "https://api.onedrive.com/v1.0/shares/$b64url/root/content"

    $dlUrl = Resolve-HttpRedirect -Url $apiUrl

    $dir = Split-Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Start-BitsTransfer -Source $dlUrl -Destination $DestinationPath `
        -DisplayName "Downloading $(Split-Path $DestinationPath -Leaf)"
}

Export-ModuleMember -Function Invoke-OneDriveDownload
