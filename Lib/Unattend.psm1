#Requires -Version 5.1
<#
.SYNOPSIS
    Per-VM unattend.xml generation and offline injection (Architecture Issues 1 + 2).

.DESCRIPTION
    The base parent VHDXs (one per OSImage type in use - see
    Lib/VmDefinitions.psm1) are sysprepped/generalized ONCE. Each of the 5
    differencing-disk children still needs its OWN hostname/IP applied at the
    specialize pass, since the parent's sysprep already ran. This module:
      1. Generates a per-VM unattend.xml (hostname, static IP, RDP enabled in
         the specialize pass - Remote Desktop is OFF by default on a fresh
         install, confirmed during /plan-eng-review's search check - and a
         known Administrator password so the trainee has something to log
         in with).
      2. Injects it offline: mount the differencing VHDX, copy to
         C:\Windows\Panther\Unattend.xml, dismount - no removable media needed.
#>

Set-StrictMode -Version Latest

function New-PerVmUnattendXml {
    <#
    .SYNOPSIS
        Builds the per-VM unattend.xml content for one VM definition.
    .DESCRIPTION
        Covers the specialize pass (computer name, static IPv4, DNS) and RDP
        enablement (Architecture Issue 2): sets fDenyTSConnections=0 via the
        TerminalServices component AND opens the "Remote Desktop" firewall
        rule group, BOTH in the specialize pass - confirmed by running this
        for real that putting the firewall command in FirstLogonCommands
        (oobeSystem) doesn't work: it only fires after an interactive logon,
        and with no AutoLogon configured, nothing ever logs in to trigger it.
        The VM just sits at first boot indefinitely, RDP never reachable.

        Also sets a known Administrator password (oobeSystem UserAccounts) -
        not a leftover secret, but a deliberate part of the design: the
        trainee needs SOME credential to RDP in and start their AD exercise,
        and without one explicitly set, Windows Server's first-boot account
        setup has nothing to fall back to and waits for input that, like the
        firewall issue above, never comes non-interactively.

        Keep every <Description> on a RunSynchronousCommand SHORT - confirmed
        by running this for real: Windows Setup's schema validator can reject
        a long/quote-heavy Description, and when it does, it invalidates the
        WHOLE unattend.xml (not just that one command) - every other setting
        in the file silently fails to apply too (static IP, hostname,
        password - everything falls back to Windows defaults, e.g. DHCP).
        setupact.log/setuperr.log in C:\Windows\Panther on the guest are the
        only way to see this failure; nothing surfaces it from the outside.
    .OUTPUTS
        [string] the unattend.xml document.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$VmDefinition,

        # Documented, known default - not a secret. The trainee uses this to
        # RDP in and start their hands-on exercise. Change before any lab
        # that isn't fully isolated/trusted.
        [string]$AdministratorPassword = 'TrainingLab@2026!'
    )

    $vm = $VmDefinition
    $dnsList = ($vm.DnsServers | ForEach-Object { "<IpAddress wcm:action=`"add`" wcm:keyValue=`"1`">$_</IpAddress>" }) -join "`n            "

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>$($vm.Name)</ComputerName>
    </component>
    <component name="Microsoft-Windows-TCPIP" processorArchitecture="amd64"
                publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>Ethernet</Identifier>
          <Ipv4Settings>
            <DhcpEnabled>false</DhcpEnabled>
          </Ipv4Settings>
          <UnicastIpAddresses>
            <IpAddress wcm:action="add" wcm:keyValue="1">$($vm.IPAddress)/$($vm.PrefixLength)</IpAddress>
          </UnicastIpAddresses>
          <Routes>
            <Route wcm:action="add">
              <Identifier>1</Identifier>
              <Prefix>0.0.0.0/0</Prefix>
              <NextHopAddress>$($vm.Gateway)</NextHopAddress>
            </Route>
          </Routes>
        </Interface>
      </Interfaces>
    </component>
    <component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64"
                publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>Ethernet</Identifier>
          <DNSServerSearchOrder>
            $dnsList
          </DNSServerSearchOrder>
        </Interface>
      </Interfaces>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64"
                publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64"
                publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>netsh advfirewall firewall add rule name="WAD_env Allow RDP 3389" dir=in action=allow protocol=TCP localport=3389</Path>
          <Description>Allow RDP</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$AdministratorPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
                publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
"@
}

function Invoke-UnattendInjection {
    <#
    .SYNOPSIS
        Offline-injects an unattend.xml into a differencing VHDX before first boot.
    .DESCRIPTION
        Mounts the VHDX, copies the answer file to <drive>:\Windows\Panther\Unattend.xml
        (the path Windows Setup checks during specialize), then dismounts. Errors
        clearly if the mount fails (e.g. the disk is locked/in use elsewhere) rather
        than leaving the VHDX in an unknown mounted state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VhdxPath,

        [Parameter(Mandatory)]
        [string]$UnattendXmlContent,

        # Overridable so tests can poll fast instead of waiting out the real
        # production timeout (see PartitionPollTimeoutSeconds below).
        [int]$PartitionPollTimeoutSeconds = 15,
        [int]$PartitionPollIntervalMs = 500
    )

    if (-not (Test-Path -LiteralPath $VhdxPath -PathType Leaf)) {
        throw "Invoke-UnattendInjection: VHDX not found at '$VhdxPath'."
    }

    $mountResult = $null
    try {
        $mountResult = Mount-VHD -Path $VhdxPath -Passthru -ErrorAction Stop
    }
    catch {
        throw "Invoke-UnattendInjection: failed to mount '$VhdxPath' - it may be locked or already in use. $($_.Exception.Message)"
    }

    try {
        # Mount-VHD does NOT auto-assign a drive letter to the mounted
        # partition - confirmed by directly inspecting a real mounted disk:
        # every partition (System/Reserved/Basic/Recovery) showed an EMPTY
        # DriveLetter, including the Basic OS partition itself, even after
        # waiting. There is nothing to "wait out" - a retry/poll loop alone
        # doesn't fix this. The partition needs an EXPLICIT drive letter
        # assignment via Add-PartitionAccessPath.
        $partition = Get-Partition -DiskNumber $mountResult.DiskNumber -ErrorAction Stop |
            Where-Object { $_.Type -eq 'Basic' } |
            Select-Object -First 1

        if (-not $partition) {
            throw "no Basic-type Windows partition was found on disk $($mountResult.DiskNumber)"
        }

        if (-not $partition.DriveLetter) {
            $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop

            # Re-query to learn which letter got assigned (poll briefly -
            # the access-path registration can lag slightly behind the call
            # returning, unlike the drive-letter assignment itself which
            # never happens on its own).
            $deadline = (Get-Date).AddSeconds($PartitionPollTimeoutSeconds)
            while (-not $partition.DriveLetter -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds $PartitionPollIntervalMs
                $partition = Get-Partition -DiskNumber $mountResult.DiskNumber -PartitionNumber $partition.PartitionNumber -ErrorAction SilentlyContinue
            }
        }

        if (-not $partition -or -not $partition.DriveLetter) {
            throw "no accessible Windows partition with a drive letter was found on disk $($mountResult.DiskNumber) after waiting ${PartitionPollTimeoutSeconds}s"
        }

        $pantherPath = "$($partition.DriveLetter):\Windows\Panther"
        if (-not (Test-Path -LiteralPath $pantherPath)) {
            New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null
        }

        $unattendDestination = Join-Path $pantherPath 'Unattend.xml'
        Set-Content -LiteralPath $unattendDestination -Value $UnattendXmlContent -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        throw "Invoke-UnattendInjection: failed to write unattend.xml into '$VhdxPath' - $($_.Exception.Message)"
    }
    finally {
        # Always attempt to dismount, even if the write failed, so a failure here
        # doesn't leave the differencing disk mounted for the next loop iteration.
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function New-PerVmUnattendXml, Invoke-UnattendInjection
