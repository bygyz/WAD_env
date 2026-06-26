#Requires -Version 5.1

Set-StrictMode -Version Latest

# System.Net.Http is not auto-loaded in Windows PowerShell 5.1.
Add-Type -AssemblyName System.Net.Http

function Invoke-HttpGet {
    # AllowAutoRedirect=true on HttpClientHandler internally uses HttpWebRequest,
    # which does NOT handle 308 ("User migrated") and throws on EnsureSuccessStatusCode.
    # AllowAutoRedirect=false + manual loop handles every 3xx code in pure PS.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)

    try {
        $current  = $Url
        $response = $null

        for ($i = 0; $i -lt 10; $i++) {
            $req      = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $current)
            $response = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result

            $code = [int]$response.StatusCode
            if ($code -ge 300 -and $code -lt 400) {
                $loc = $response.Headers.Location
                $response.Dispose(); $response = $null
                if ($null -eq $loc) { throw "HTTP $code redirect with no Location header from '$current'" }
                if (-not $loc.IsAbsoluteUri) {
                    $loc = [System.Uri]::new([System.Uri]::new($current), $loc)
                }
                $current = $loc.AbsoluteUri
                continue
            }
            break
        }

        if ($null -eq $response) { throw "Invoke-HttpGet: too many redirects for '$Url'" }
        $response.EnsureSuccessStatusCode() | Out-Null

        $contentLength = $response.Content.Headers.ContentLength
        $srcStream     = $response.Content.ReadAsStreamAsync().Result
        $fileStream    = [System.IO.FileStream]::new(
            $DestinationPath, [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 81920)
        try {
            $buffer    = [byte[]]::new(81920)
            $totalRead = 0L
            $fileName  = Split-Path $DestinationPath -Leaf

            while (($read = $srcStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $totalRead += $read
                if ($contentLength -gt 0) {
                    $pct    = [int]([double]$totalRead / $contentLength * 100)
                    $readMB = [math]::Round($totalRead / 1MB, 1)
                    $totGB  = [math]::Round($contentLength / 1GB, 2)
                    Write-Progress -Activity "Downloading $fileName" `
                        -Status "$readMB MB of $totGB GB" -PercentComplete $pct
                }
            }
            Write-Progress -Activity "Downloading $fileName" -Completed
        }
        finally {
            $fileStream.Close()
            $srcStream.Close()
        }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-OneDriveDownload {
    <#
    .SYNOPSIS
        Downloads a file from a OneDrive or SharePoint sharing link.
    .DESCRIPTION
        Supports both personal OneDrive (1drv.ms / onedrive.live.com) and
        SharePoint / OneDrive for Business (*.sharepoint.com) sharing links:

          - sharepoint.com URLs: appends &download=1 to force direct file
            download instead of the sharing/preview page.
          - Personal OneDrive URLs: encodes the link via the OneDrive API
            base64url scheme (api.onedrive.com/v1.0/shares/u!.../root/content).

        In both cases the download uses HttpClient with AllowAutoRedirect=false
        and a manual redirect loop, so all 3xx codes including 308 "User migrated"
        are handled. The destination directory is created if it doesn't exist.
        Download progress is reported via Write-Progress in the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SharingUrl,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $uri = [System.Uri]::new($SharingUrl)
    if ($uri.Host -match 'sharepoint\.com$') {
        # SharePoint / OneDrive for Business sharing links already carry ?e=<token>.
        # Appending &download=1 forces the raw file bytes instead of the HTML
        # preview/redirect page that the sharing URL normally opens.
        $dlUrl = if ($uri.Query) { "$SharingUrl&download=1" } else { "$SharingUrl?download=1" }
    }
    else {
        # Personal OneDrive (1drv.ms, onedrive.live.com): base64url-encode the
        # full sharing URL and call the OneDrive API /shares endpoint.
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($SharingUrl)
        $b64    = [Convert]::ToBase64String($bytes)
        $b64url = 'u!' + $b64.TrimEnd('=').Replace('/', '_').Replace('+', '-')
        $dlUrl  = "https://api.onedrive.com/v1.0/shares/$b64url/root/content"
    }

    $dir = Split-Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Invoke-HttpGet -Url $dlUrl -DestinationPath $DestinationPath
}

Export-ModuleMember -Function Invoke-OneDriveDownload
