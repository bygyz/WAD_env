#Requires -Version 5.1
#Requires -Modules Hyper-V
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys the AD training lab: configurable counts of Domain A DCs
    (corp.lab), Domain B DCs (partner.lab, trust-practice), and clients
    (Domain A) - see Get-LabVmDefinitions for the Count parameters.

.DESCRIPTION
    Builds clean, networked, hostnamed VMs and stops BEFORE any AD DS
    promotion, DNS/DHCP config, or OU/GPO setup - that is 100% the trainee's
    hands-on exercise (design doc Constraints/Premises). This script's job
    ends at "every VM is up and RDP-reachable," checkpointed as 00-baseline.

    Locked decisions this script implements (see eng-review):
      - Issue 1: per-VM unattend.xml via offline VHDX injection
      - Issue 2: RDP enabled via unattend.xml specialize-pass RunSynchronous
        (not FirstLogonCommands - that depends on an interactive logon that
        never happens non-interactively, confirmed by running this for real)
      - Issue 3: parent VHDX must be read-only before use (verified, not just set)
      - Issue 4: pre-flight ping check on every reserved IP before touching any VM
      - Issue 5: timestamped transcript log per run
      - Issue 8: sequential VM creation/boot with a stagger, not parallel
      - Issue 9: Production checkpoints (Hyper-V's Gen2 default) for 00-baseline
      - Issue 11: disk-space pre-flight check before creating new differencing disks
      - Constraints line 25: on any mid-loop failure, abort and report which VMs
        were created - no automatic partial cleanup (Reset.ps1 handles that).

.PARAMETER SwitchName
    Name of the external/bridged Hyper-V virtual switch. Created if missing.

.PARAMETER ExternalAdapterName
    Physical network adapter to bind the external switch to, if the switch
    needs to be created. Required on first run only.

.PARAMETER VmStorageRoot
    Where differencing disks + VM config live (NOT the parent image path).

.PARAMETER StaggerSeconds
    Delay between finishing one VM's checkpoint and starting the next VM's
    differencing-disk creation - mitigates I/O contention on the shared
    parent VHDXs (Performance Issue 8).

.PARAMETER RdpTimeoutSeconds
    How long to wait for each VM's RDP port to come up before treating that
    VM as failed (not checkpointed).

.PARAMETER MinFreeDiskGB
    Pre-flight disk-space threshold on the VmStorageRoot volume (Issue 11).

.PARAMETER DomainAServerCount
.PARAMETER DomainBServerCount
.PARAMETER ClientCount
    How many VMs to build per role - see Get-LabVmDefinitions for the exact
    naming/IP-allocation rules these drive.

.PARAMETER NetworkConfig
    Override the placeholder IP block (Lib/VmDefinitions.psm1's default) -
    see Get-LabVmDefinitions for the expected shape. Omit to use the default.

.PARAMETER NameOverrides
    Hashtable keyed by canonical generated name (DC1, DC2, ..., PDC1, ...,
    CL1, ...) renaming that VM's actual hostname - see Get-LabVmDefinitions
    for why this is safe.

.PARAMETER IPOverrides
    Hashtable keyed by canonical generated name, overriding that VM's
    auto-allocated IP - see Get-LabVmDefinitions.

.PARAMETER ParentImageRoot
    Override where sysprepped parent VHDXs live (Lib/ParentImage.psm1's
    default). Omit to use the default F:\WAD_env\ParentImages (or a
    script-relative path with no F:\ drive).
#>
[CmdletBinding()]
param(
    [string]$SwitchName = 'LabBridge',
    [string]$ExternalAdapterName,
    # Defaults to F:\ when it exists - differencing disks need real room and
    # the system drive may not have it (caught by actually running this: the
    # test host's C: only had 8.7GB free). Override explicitly on hosts
    # without a dedicated F:\ drive.
    [string]$VmStorageRoot = $(if (Test-Path -LiteralPath 'F:\') { 'F:\WAD_env\VMs' } else { Join-Path $PSScriptRoot 'VMs' }),
    [int]$StaggerSeconds = 20,
    [int]$RdpTimeoutSeconds = 300,
    [int]$MinFreeDiskGB = 20,
    # Every VM's Administrator account gets this password - override before
    # deploying anywhere that isn't fully isolated/trusted (see README).
    [string]$AdministratorPassword = 'TrainingLab@2026!',
    [int]$DomainAServerCount = 2,
    [int]$DomainBServerCount = 1,
    [int]$ClientCount = 2,
    [PSCustomObject]$NetworkConfig,
    [hashtable]$NameOverrides = @{},
    [hashtable]$IPOverrides = @{},
    [string]$ParentImageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Lib\Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lib\DiskBudget.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lib\VmDefinitions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lib\ParentImage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lib\Unattend.psm1') -Force

if ($ParentImageRoot) {
    Set-ParentImageRoot -Path $ParentImageRoot
}

function Ensure-LabSwitch {
    param([string]$Name, [string]$AdapterName)

    $existing = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.SwitchType -ne 'External') {
            throw "Ensure-LabSwitch: a switch named '$Name' already exists but is type '$($existing.SwitchType)', not External. This design requires a full bridged/external switch (design doc Constraints line 19) - rename or remove the existing switch first."
        }
        return
    }

    if (-not $AdapterName) {
        throw "Ensure-LabSwitch: switch '$Name' does not exist and -ExternalAdapterName was not supplied. Pass the physical NIC to bridge (e.g. Get-NetAdapter to list candidates)."
    }

    Write-LabLog "Creating external/bridged switch '$Name' on adapter '$AdapterName'."
    New-VMSwitch -Name $Name -NetAdapterName $AdapterName -AllowManagementOS $true | Out-Null
}

function Test-TcpPortOpen {
    # Test-NetConnection can block far longer than its own timeout suggests
    # on this nested-virtualization host - confirmed by running this for
    # real: the deploy process froze completely (CPU flat, no log writes)
    # mid-poll, with no recovery until manually killed. TcpClient.ConnectAsync
    # + Task.Wait(ms) has a HARD timeout: Wait() always returns within the
    # specified time regardless of what the underlying connect attempt is
    # doing, so the caller's retry loop can never get stuck here.
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$ConnectTimeoutMs = 5000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $parsedIp = [System.Net.IPAddress]::Parse($IPAddress)
        $connectTask = $client.ConnectAsync($parsedIp, $Port)
        if (-not $connectTask.Wait($ConnectTimeoutMs)) {
            # Deliberately NOT disposing $client here. Confirmed by running
            # this for real: on this nested-virtualization host, a filtered/
            # black-holed route can leave the OS-level TCP connect attempt
            # pending well past our 5s application-level wait - and disposing
            # a TcpClient with a still-pending ConnectAsync can itself block
            # until that underlying attempt resolves, moving the hang from
            # Wait() to Close() instead (this happened: Wait() returned fine,
            # the deploy loop still froze solid). A few abandoned sockets
            # across failed probes is a harmless tradeoff against a hang.
            return $false
        }
        $connected = $client.Connected
        $client.Close()
        return $connected
    }
    catch {
        return $false
    }
}

function Wait-ForRdpReady {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$IPAddress,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPortOpen -IPAddress $IPAddress -Port 3389 -ConnectTimeoutMs 5000) {
            return $true
        }
        Start-Sleep -Seconds 10
    }
    return $false
}

$logPath = Start-LabLog -RunType 'Deploy'
$createdVMs = [System.Collections.Generic.List[string]]::new()
$checkpointedVMs = [System.Collections.Generic.List[string]]::new()

try {
    Write-LabLog "Deploy run starting. Log: $logPath"

    # --- Pre-flight checks, BEFORE any VM is touched ---
    Assert-LabDiskSpace -Path $VmStorageRoot -MinFreeGB $MinFreeDiskGB | Out-Null
    Write-LabLog "Disk-space pre-flight OK (>= $MinFreeDiskGB GB free)."

    # Derived from the actual VM definitions, not a hardcoded list - so this
    # can never drift out of sync with whatever OS images the topology
    # actually uses (it did once already, when Client10 was dropped).
    # -NetworkConfig is only passed through when the caller actually supplied
    # one - Get-LabVmDefinitions' own default lives in VmDefinitions.psm1's
    # module scope, not reachable as a param-block default here.
    $vmDefs = if ($NetworkConfig) {
        Get-LabVmDefinitions -DomainAServerCount $DomainAServerCount -DomainBServerCount $DomainBServerCount `
            -ClientCount $ClientCount -NetworkConfig $NetworkConfig -NameOverrides $NameOverrides -IPOverrides $IPOverrides
    }
    else {
        Get-LabVmDefinitions -DomainAServerCount $DomainAServerCount -DomainBServerCount $DomainBServerCount `
            -ClientCount $ClientCount -NameOverrides $NameOverrides -IPOverrides $IPOverrides
    }
    foreach ($osImage in ($vmDefs.OSImage | Sort-Object -Unique)) {
        $parentPath = Get-ParentImagePath -OSImage $osImage
        if (-not (Test-ParentImageProtected -Path $parentPath)) {
            throw "Parent image '$parentPath' is not read-only. Run Protect-ParentImage on it before deploying - an unprotected parent is not safe to build differencing disks from."
        }
    }
    Write-LabLog 'Parent image protection verified for all required OS images.'

    Test-LabIPBlockAvailable -VmDefinitions $vmDefs
    Write-LabLog "Pre-flight IP availability check passed for all $($vmDefs.Count) reserved addresses."

    Ensure-LabSwitch -Name $SwitchName -AdapterName $ExternalAdapterName
    if (-not (Test-Path -LiteralPath $VmStorageRoot)) {
        New-Item -ItemType Directory -Path $VmStorageRoot -Force | Out-Null
    }

    # --- Sequential, staggered VM build (Issue 8) ---
    foreach ($vm in $vmDefs) {
        Write-LabLog "Building $($vm.Name) ($($vm.OSImage), $($vm.Domain)) at $($vm.IPAddress)..."

        $parentPath = Get-ParentImagePath -OSImage $vm.OSImage
        $vmDir = Join-Path $VmStorageRoot $vm.Name
        New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
        $diffDiskPath = Join-Path $vmDir "$($vm.Name).vhdx"

        New-VHD -Path $diffDiskPath -ParentPath $parentPath -Differencing | Out-Null
        Write-LabLog "  Differencing disk created: $diffDiskPath"

        $unattendXml = New-PerVmUnattendXml -VmDefinition $vm -AdministratorPassword $AdministratorPassword
        Invoke-UnattendInjection -VhdxPath $diffDiskPath -UnattendXmlContent $unattendXml
        Write-LabLog '  unattend.xml injected.'

        New-VM -Name $vm.Name -Generation 2 -MemoryStartupBytes 2GB -VHDPath $diffDiskPath -SwitchName $SwitchName -Path $vmDir | Out-Null
        if ($vm.Role -eq 'Client') {
            Set-VMMemory -VMName $vm.Name -StartupBytes 4GB
        }
        Set-VMProcessor -VMName $vm.Name -Count 2

        # Needed when the External switch's underlying adapter is itself a
        # virtual NIC (nested Hyper-V running inside another hypervisor, e.g.
        # VMware Workstation) - confirmed by running this for real: without
        # this, the host's outer virtualization layer can intermittently
        # drop frames carrying this VM's own (non-default) MAC address.
        # Harmless and unnecessary on bare-metal Hyper-V hosts.
        Set-VMNetworkAdapter -VMName $vm.Name -MacAddressSpoofing On

        $createdVMs.Add($vm.Name)
        Write-LabLog "  VM '$($vm.Name)' created."

        Start-VM -Name $vm.Name
        Write-LabLog "  VM '$($vm.Name)' started, waiting for RDP (timeout ${RdpTimeoutSeconds}s)..."

        $rdpReady = Wait-ForRdpReady -VMName $vm.Name -IPAddress $vm.IPAddress -TimeoutSeconds $RdpTimeoutSeconds
        if (-not $rdpReady) {
            throw "'$($vm.Name)' did not become RDP-reachable within $RdpTimeoutSeconds seconds. NOT checkpointed - check the unattend.xml specialize-pass RunSynchronous command on this VM before retrying."
        }

        # Production checkpoints are Hyper-V's default for Generation 2 VMs on
        # Server 2016+/Windows 10+ (Performance Issue 9) - explicit here so the
        # choice is documented, not implicit.
        Checkpoint-VM -Name $vm.Name -SnapshotName '00-baseline'
        $checkpointedVMs.Add($vm.Name)
        Write-LabLog "  '$($vm.Name)' RDP-reachable and checkpointed as 00-baseline."

        if ($vm -ne $vmDefs[-1]) {
            Write-LabLog "  Staggering ${StaggerSeconds}s before next VM to avoid parent-VHDX I/O contention."
            Start-Sleep -Seconds $StaggerSeconds
        }
    }

    Write-LabLog "Deploy complete. $($checkpointedVMs.Count)/$($vmDefs.Count) VMs created, RDP-reachable, and checkpointed at 00-baseline."
}
catch {
    Write-LabLog "Deploy FAILED: $($_.Exception.Message)" -Level 'ERROR'
    Write-LabLog "VMs created this run: $($createdVMs -join ', ')" -Level 'WARN'
    Write-LabLog "VMs checkpointed this run: $($checkpointedVMs -join ', ')" -Level 'WARN'
    Write-LabLog 'No automatic cleanup was performed (by design - Constraints line 25). Run Reset.ps1 to tear down or restore before retrying.' -Level 'WARN'
    throw
}
finally {
    Stop-LabLog
}
