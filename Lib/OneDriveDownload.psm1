#Requires -Version 5.1

Set-StrictMode -Version Latest

function Resolve-HttpRedirect {
    # BITS does not follow HTTP redirects on its own (confirmed: 302 → "HTTP
    # redirect required"). HttpWebRequest with AllowAutoRedirect=true handles
    # 301/302/303/307 but throws on 308 "User migrated" (confirmed: OneDrive
    # uses 308 when a personal OneDrive account is homed on a different server).
    # Manual loop with AllowAutoRedirect=false handles every 3xx code.
    param([Parameter(Mandatory)][string]$Url)

    $current = $Url
    for ($i = 0; $i -lt 10; $i++) {
        $req                   = [System.Net.HttpWebRequest]::Create($current)
        $req.Method            = 'HEAD'
        $req.AllowAutoRedirect = $false

        $resp       = $req.GetResponse()
        $statusCode = [int]$resp.StatusCode
        $location   = $resp.Headers['Location']
        $resp.Close()

        if ($statusCode -ge 300 -and $statusCode -lt 400 -and $location) {
            if ($location -notmatch '^https?://') {
                $location = [System.Uri]::new([System.Uri]::new($current), $location).AbsoluteUri
            }
            $current = $location
            continue
        }
        return $current
    }
    throw "Resolve-HttpRedirect: too many redirects starting from '$Url'"
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
