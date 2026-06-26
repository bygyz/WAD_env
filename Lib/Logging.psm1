#Requires -Version 5.1
<#
.SYNOPSIS
    Timestamped run logging for Deploy.ps1 / Reset.ps1 (Code Quality Issue 5).

.DESCRIPTION
    A run that fails at 2am before a training session needs a record of which
    step failed and why, beyond whatever scrolled past in the console. Shared
    by both orchestration scripts so the log format and location stay
    consistent (DRY - this was duplicated logic in the original task split,
    factored out here instead).
#>

Set-StrictMode -Version Latest

$Script:LogsRoot = Join-Path $PSScriptRoot '..\Logs'
$Script:CurrentLogPath = $null

function Start-LabLog {
    <#
    .SYNOPSIS
        Starts a timestamped transcript for this run. Call once at the top of
        Deploy.ps1 / Reset.ps1.
    .OUTPUTS
        [string] the log file path, for reference in the run's final summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Deploy', 'Reset')]
        [string]$RunType
    )

    if (-not (Test-Path -LiteralPath $Script:LogsRoot)) {
        New-Item -ItemType Directory -Path $Script:LogsRoot -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Script:CurrentLogPath = Join-Path $Script:LogsRoot "$RunType-$timestamp.log"

    # Create the file explicitly rather than relying solely on Start-Transcript's
    # side effect - if a transcript is already active in this host process
    # (e.g. an outer caller's own Start-Transcript), Start-Transcript here can
    # silently no-op, and callers checking the returned path would find nothing
    # (confirmed: this happened intermittently when run inside another
    # transcript's scope). Pre-creating the file makes the contract hold either way.
    if (-not (Test-Path -LiteralPath $Script:CurrentLogPath)) {
        New-Item -ItemType File -Path $Script:CurrentLogPath -Force | Out-Null
    }
    Start-Transcript -Path $Script:CurrentLogPath -Append | Out-Null
    return $Script:CurrentLogPath
}

function Write-LabLog {
    <#
    .SYNOPSIS
        Writes a timestamped, leveled line to both the console and the active
        transcript.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'WARN'  { Write-Warning $line }
        'ERROR' { Write-Error $line -ErrorAction Continue }
        default { Write-Host $line }
    }
}

function Stop-LabLog {
    <#
    .SYNOPSIS
        Stops the transcript started by Start-LabLog. Safe to call even if no
        transcript is active (e.g. in a finally block after an early failure).
    #>
    [CmdletBinding()]
    param()

    try { Stop-Transcript | Out-Null } catch { }
}

Export-ModuleMember -Function Start-LabLog, Write-LabLog, Stop-LabLog
