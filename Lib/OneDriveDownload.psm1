#Requires -Version 5.1

Set-StrictMode -Version Latest

# System.Net.Http is not auto-loaded in Windows PowerShell 5.1 — HttpClient
# and HttpClientHandler are unavailable until this assembly is explicitly added.
Add-Type -AssemblyName System.Net.Http

function Invoke-HttpGet {
    # HttpClient handles all 3xx redirects including 308 "User migrated" —
    # confirmed that HttpWebRequest-based tools (Start-BitsTransfer, WebClient,
    # Invoke-WebRequest on PS 5.1) do NOT handle 308 and throw "HTTP redirect
    # required". ResponseHeadersRead + manual stream-copy avoids buffering a
    # 15-20 GB file in memory. Write-Progress shows a real percentage.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client  = [System.Net.Http.HttpClient]::new($handler)
    try {
        $response = $client.GetAsync(
            $Url,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).Result
        $response.EnsureSuccessStatusCode() | Out-Null

        $contentLength = $response.Content.Headers.ContentLength
        $srcStream  = $response.Content.ReadAsStreamAsync().Result
        $fileStream = [System.IO.FileStream]::new(
            $DestinationPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            81920)
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
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-OneDriveDownload {
    <#
    .SYNOPSIS
        Downloads a file from a personal OneDrive sharing link.
    .DESCRIPTION
        Converts a personal OneDrive sharing URL (https://1drv.ms/...) to the
        OneDrive API base64url URL and downloads the file via HttpClient.
        HttpClient follows all HTTP redirects including 308 "User migrated"
        (issued when the OneDrive account is homed on a geo-specific server).
        The destination directory is created automatically if it doesn't exist.
        Download progress is reported via Write-Progress in the console.
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

    $dir = Split-Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Invoke-HttpGet -Url $apiUrl -DestinationPath $DestinationPath
}

Export-ModuleMember -Function Invoke-OneDriveDownload
