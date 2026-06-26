#Requires -Version 5.1
<#
.SYNOPSIS
    GUI front-end for Deploy.ps1 - lets a trainer tune VM counts, names, IPs,
    the sysprep template path, and host settings without editing any script
    or remembering CLI flags, then runs Deploy.ps1 with the chosen values.

.DESCRIPTION
    Pure convenience layer: this script never touches Hyper-V itself. It
    collects input, then calls Deploy.ps1 with the equivalent parameters in
    the SAME console window, so Deploy.ps1's normal log output streams live
    exactly as if it had been run directly. Deploy.ps1 itself is untouched -
    still fully scriptable/headless, still covered by the Pester suite.

    The VM list (names + IPs) updates live as counts or network settings
    change, so what you see before clicking Deploy is exactly what will be
    built. Edit the Name or IP Address cell directly to rename a VM or give
    it an arbitrary, non-sequential address - edits survive further count/
    network field changes as long as that row still exists.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Checked here (with a clear popup) rather than relying solely on Deploy.ps1's
# own #Requires -RunAsAdministrator - confirmed by running this for real:
# without elevation, the wizard form fills out fine and only fails deep into
# Deploy.ps1's run (New-VMSwitch specifically needs elevation, even for an
# Administrators-group member, due to UAC) - a confusing way to discover this
# after already choosing all the settings. Catching it before the form even
# opens is a much better experience.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        "This wizard needs to run as Administrator (Hyper-V switch/VM creation requires it, even for an Administrators-group member, due to UAC).`n`nClose this and re-launch by right-clicking Start-LabDeployWizard.ps1 (or your PowerShell shortcut) and choosing 'Run as Administrator'.",
        'WAD_env - Elevation required',
        'OK',
        'Warning'
    ) | Out-Null
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'Lib\VmDefinitions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Lib\ParentImage.psm1') -Force

function New-VmPreviewRows {
    param($DomainACount, $DomainBCount, $ClientCount, $BaseIP, $Prefix, $Gateway, $Dns, $NameOverridesTable, $IPOverridesTable = @{})

    $networkConfig = [PSCustomObject]@{
        SubnetPrefixLength = $Prefix
        Gateway            = $Gateway
        DnsServers         = @($Dns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        BaseIPAddress      = $BaseIP
    }

    return Get-LabVmDefinitions -DomainAServerCount $DomainACount -DomainBServerCount $DomainBCount `
        -ClientCount $ClientCount -NetworkConfig $networkConfig -NameOverrides $NameOverridesTable -IPOverrides $IPOverridesTable
}

# ---------------------------------------------------------------------------
# Form + controls
# ---------------------------------------------------------------------------

$form = [System.Windows.Forms.Form]@{
    Text          = 'WAD_env - Lab Deploy Wizard'
    Size          = [System.Drawing.Size]::new(720, 820)
    StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'
    MaximizeBox   = $false
}

$y = 10

function Add-Label {
    param($Text, $X = 10, [ref]$YRef)
    $lbl = [System.Windows.Forms.Label]@{ Text = $Text; Location = [System.Drawing.Point]::new($X, $YRef.Value); AutoSize = $true }
    $form.Controls.Add($lbl)
    return $lbl
}

# --- Topology group ---
$grpTopology = [System.Windows.Forms.GroupBox]@{
    Text = 'Topology - how many VMs per role'
    Location = [System.Drawing.Point]::new(10, $y)
    Size = [System.Drawing.Size]::new(690, 80)
}
$form.Controls.Add($grpTopology)

$lblA = [System.Windows.Forms.Label]@{ Text = 'Domain A servers (corp.lab):'; Location = [System.Drawing.Point]::new(10, 25); AutoSize = $true }
$numA = [System.Windows.Forms.NumericUpDown]@{ Location = [System.Drawing.Point]::new(190, 22); Width = 50; Minimum = 1; Maximum = 99; Value = 2 }
$lblB = [System.Windows.Forms.Label]@{ Text = 'Domain B servers (partner.lab, 0=skip):'; Location = [System.Drawing.Point]::new(260, 25); AutoSize = $true }
$numB = [System.Windows.Forms.NumericUpDown]@{ Location = [System.Drawing.Point]::new(520, 22); Width = 50; Minimum = 0; Maximum = 99; Value = 1 }
$lblC = [System.Windows.Forms.Label]@{ Text = 'Clients:'; Location = [System.Drawing.Point]::new(10, 55); AutoSize = $true }
$numC = [System.Windows.Forms.NumericUpDown]@{ Location = [System.Drawing.Point]::new(190, 52); Width = 50; Minimum = 0; Maximum = 99; Value = 2 }
$grpTopology.Controls.AddRange([System.Windows.Forms.Control[]]@($lblA, $numA, $lblB, $numB, $lblC, $numC))

$y += 90

# --- Network group ---
$grpNetwork = [System.Windows.Forms.GroupBox]@{
    Text = 'Network'
    Location = [System.Drawing.Point]::new(10, $y)
    Size = [System.Drawing.Size]::new(690, 110)
}
$form.Controls.Add($grpNetwork)

$lblBaseIp = [System.Windows.Forms.Label]@{ Text = 'Base IP address (first VM gets this, rest increment by 1):'; Location = [System.Drawing.Point]::new(10, 25); AutoSize = $true }
$txtBaseIp = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(10, 45); Width = 150; Text = '192.168.1.241' }
$lblPrefix = [System.Windows.Forms.Label]@{ Text = 'Prefix length:'; Location = [System.Drawing.Point]::new(180, 25); AutoSize = $true }
$numPrefix = [System.Windows.Forms.NumericUpDown]@{ Location = [System.Drawing.Point]::new(180, 45); Width = 50; Minimum = 1; Maximum = 32; Value = 24 }
$lblGateway = [System.Windows.Forms.Label]@{ Text = 'Gateway:'; Location = [System.Drawing.Point]::new(250, 25); AutoSize = $true }
$txtGateway = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(250, 45); Width = 150; Text = '192.168.1.1' }
$lblDns = [System.Windows.Forms.Label]@{ Text = 'DNS server(s), comma-separated:'; Location = [System.Drawing.Point]::new(10, 78); AutoSize = $true }
$txtDns = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(250, 75); Width = 200; Text = '192.168.1.1' }
$grpNetwork.Controls.AddRange([System.Windows.Forms.Control[]]@($lblBaseIp, $txtBaseIp, $lblPrefix, $numPrefix, $lblGateway, $txtGateway, $lblDns, $txtDns))

$y += 120

# --- VM preview grid ---
$lblGrid = [System.Windows.Forms.Label]@{ Text = 'VMs to be created (edit Name or IP Address to override either; Domain/Role are computed):'; Location = [System.Drawing.Point]::new(10, $y); AutoSize = $true }
$form.Controls.Add($lblGrid)
$y += 22

$grid = [System.Windows.Forms.DataGridView]@{
    Location = [System.Drawing.Point]::new(10, $y)
    Size = [System.Drawing.Size]::new(690, 180)
    AllowUserToAddRows = $false
    AllowUserToDeleteRows = $false
    SelectionMode = 'CellSelect'
    RowHeadersVisible = $false
}
$colName = [System.Windows.Forms.DataGridViewTextBoxColumn]@{ Name = 'Canonical'; HeaderText = 'Canonical'; Visible = $false }
$colCanonicalIp = [System.Windows.Forms.DataGridViewTextBoxColumn]@{ Name = 'CanonicalIP'; HeaderText = 'CanonicalIP'; Visible = $false }
$colEditName = [System.Windows.Forms.DataGridViewTextBoxColumn]@{ Name = 'Name'; HeaderText = 'Name (editable)'; Width = 180 }
$colDomain = [System.Windows.Forms.DataGridViewTextBoxColumn]@{ Name = 'Domain'; HeaderText = 'Domain'; Width = 130; ReadOnly = $true }
$colRole = [System.Windows.Forms.DataGridViewTextBoxColumn]@{ Name = 'Role'; HeaderText = 'Role'; Width = 130; ReadOnly = $true }
$colIp = [System.Windows.Forms.DataGridViewTextBoxColumn]@{ Name = 'IPAddress'; HeaderText = 'IP Address (editable)'; Width = 150 }
$grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colName, $colCanonicalIp, $colEditName, $colDomain, $colRole, $colIp))
$form.Controls.Add($grid)

$y += 190

# --- Host & security group ---
$grpHost = [System.Windows.Forms.GroupBox]@{
    Text = 'Host & security'
    Location = [System.Drawing.Point]::new(10, $y)
    Size = [System.Drawing.Size]::new(690, 215)
}
$form.Controls.Add($grpHost)

$lblSwitch = [System.Windows.Forms.Label]@{ Text = 'Hyper-V switch name:'; Location = [System.Drawing.Point]::new(10, 25); AutoSize = $true }
$txtSwitch = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(180, 22); Width = 150; Text = 'LabBridge' }
$lblAdapter = [System.Windows.Forms.Label]@{ Text = 'External adapter (first run only):'; Location = [System.Drawing.Point]::new(350, 25); AutoSize = $true }
$cmbAdapter = [System.Windows.Forms.ComboBox]@{ Location = [System.Drawing.Point]::new(350, 45); Width = 320; DropDownStyle = 'DropDown' }
try {
    Get-NetAdapter -ErrorAction Stop | ForEach-Object { $cmbAdapter.Items.Add($_.Name) | Out-Null }
}
catch {
    # Get-NetAdapter not available on this host (e.g. running the wizard
    # somewhere other than the actual Hyper-V host) - leave the dropdown
    # empty and let the trainer type the adapter name manually.
}

$lblVmRoot = [System.Windows.Forms.Label]@{ Text = 'VM storage root:'; Location = [System.Drawing.Point]::new(10, 75); AutoSize = $true }
$txtVmRoot = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(180, 72); Width = 380; Text = $(if (Test-Path -LiteralPath 'F:\') { 'F:\WAD_env\VMs' } else { Join-Path $PSScriptRoot 'VMs' }) }
$btnVmRoot = [System.Windows.Forms.Button]@{ Text = 'Browse...'; Location = [System.Drawing.Point]::new(570, 71); Width = 90 }

# Per-image file pickers — browse directly to the template .vhdx for each OS,
# no copy or rename required. The wizard auto-protects (sets read-only) any
# file that isn't already protected when Deploy is clicked.
$defaultParentRoot = if (Test-Path -LiteralPath 'F:\') { 'F:\WAD_env\ParentImages' } else { Join-Path $PSScriptRoot 'ParentImages' }

$lblServer2022 = [System.Windows.Forms.Label]@{ Text = 'Server 2022 image (.vhdx):'; Location = [System.Drawing.Point]::new(10, 108); AutoSize = $true }
$txtServer2022 = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(180, 105); Width = 380; Text = (Join-Path $defaultParentRoot 'Server2022-Base.vhdx') }
$btnServer2022 = [System.Windows.Forms.Button]@{ Text = 'Browse...'; Location = [System.Drawing.Point]::new(570, 104); Width = 90 }

$lblClient11 = [System.Windows.Forms.Label]@{ Text = 'Windows 11 image (.vhdx):'; Location = [System.Drawing.Point]::new(10, 141); AutoSize = $true }
$txtClient11 = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(180, 138); Width = 380; Text = (Join-Path $defaultParentRoot 'Client11-Base.vhdx') }
$btnClient11 = [System.Windows.Forms.Button]@{ Text = 'Browse...'; Location = [System.Drawing.Point]::new(570, 137); Width = 90 }

$lblPassword = [System.Windows.Forms.Label]@{ Text = 'Administrator password (every VM):'; Location = [System.Drawing.Point]::new(10, 174); AutoSize = $true }
$txtPassword = [System.Windows.Forms.TextBox]@{ Location = [System.Drawing.Point]::new(260, 171); Width = 200; Text = 'TrainingLab@2026!'; UseSystemPasswordChar = $true }

$grpHost.Controls.AddRange([System.Windows.Forms.Control[]]@(
    $lblSwitch, $txtSwitch, $lblAdapter, $cmbAdapter,
    $lblVmRoot, $txtVmRoot, $btnVmRoot,
    $lblServer2022, $txtServer2022, $btnServer2022,
    $lblClient11, $txtClient11, $btnClient11,
    $lblPassword, $txtPassword
))

$btnVmRoot.Add_Click({
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtVmRoot.Text = $dlg.SelectedPath
    }
})

function New-VhdxOpenDialog {
    param([string]$Title, [string]$CurrentPath)
    $dlg = [System.Windows.Forms.OpenFileDialog]@{
        Title  = $Title
        Filter = 'VHDX files (*.vhdx)|*.vhdx|All files (*.*)|*.*'
    }
    $dir = try { Split-Path $CurrentPath -Parent } catch { '' }
    if ($dir -and (Test-Path -LiteralPath $dir)) { $dlg.InitialDirectory = $dir }
    return $dlg
}

$btnServer2022.Add_Click({
    $dlg = New-VhdxOpenDialog -Title 'Select Windows Server 2022 template (.vhdx)' -CurrentPath $txtServer2022.Text
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtServer2022.Text = $dlg.FileName
    }
})
$btnClient11.Add_Click({
    $dlg = New-VhdxOpenDialog -Title 'Select Windows 11 template (.vhdx)' -CurrentPath $txtClient11.Text
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtClient11.Text = $dlg.FileName
    }
})

$y += 225

# --- Buttons ---
$btnDeploy = [System.Windows.Forms.Button]@{ Text = 'Deploy'; Location = [System.Drawing.Point]::new(520, $y); Width = 90; Height = 30 }
$btnCancel = [System.Windows.Forms.Button]@{ Text = 'Cancel'; Location = [System.Drawing.Point]::new(610, $y); Width = 90; Height = 30 }
$form.Controls.AddRange([System.Windows.Forms.Control[]]@($btnDeploy, $btnCancel))

# ---------------------------------------------------------------------------
# Live preview refresh - re-derives the VM list from current field values
# whenever a topology/network field changes, so the grid never goes stale.
# ---------------------------------------------------------------------------

function Update-PreviewGrid {
    # Preserve any edits already made to the Name/IPAddress columns, keyed by
    # the canonical name/IP, so changing a count/network field doesn't wipe
    # out renames or re-IPs the trainer already typed for rows that still
    # exist. CanonicalIP (hidden) is what "still has its auto-allocated
    # value" is compared against, the same way Canonical (hidden) works for
    # names.
    $existingNameOverrides = @{}
    $existingIpOverrides = @{}
    foreach ($row in $grid.Rows) {
        $canonical = $row.Cells['Canonical'].Value
        $canonicalIp = $row.Cells['CanonicalIP'].Value
        $editedName = $row.Cells['Name'].Value
        $editedIp = $row.Cells['IPAddress'].Value
        if ($canonical -and $editedName -and $editedName -ne $canonical) {
            $existingNameOverrides[$canonical] = $editedName
        }
        if ($canonical -and $editedIp -and $editedIp -ne $canonicalIp) {
            $existingIpOverrides[$canonical] = $editedIp
        }
    }

    try {
        $rows = New-VmPreviewRows -DomainACount $numA.Value -DomainBCount $numB.Value -ClientCount $numC.Value `
            -BaseIP $txtBaseIp.Text -Prefix $numPrefix.Value -Gateway $txtGateway.Text -Dns $txtDns.Text `
            -NameOverridesTable $existingNameOverrides -IPOverridesTable $existingIpOverrides
    }
    catch {
        # Invalid IP/count combination (e.g. would run past .255) - leave the
        # grid as-is rather than crashing the wizard; the error surfaces for
        # real when Deploy.ps1 itself validates on click.
        return
    }

    # Recover the canonical (un-renamed, un-re-IPed) name/IP for each row by
    # rebuilding the same list with no overrides and matching by position -
    # generation order is deterministic for a given set of counts, so this is
    # a safe, simple way to know "what was this row before any override" for
    # the next refresh's existing-overrides pass above.
    $canonicalRows = New-VmPreviewRows -DomainACount $numA.Value -DomainBCount $numB.Value -ClientCount $numC.Value `
        -BaseIP $txtBaseIp.Text -Prefix $numPrefix.Value -Gateway $txtGateway.Text -Dns $txtDns.Text `
        -NameOverridesTable @{} -IPOverridesTable @{}

    $grid.Rows.Clear()
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $grid.Rows.Add($canonicalRows[$i].Name, $canonicalRows[$i].IPAddress, $rows[$i].Name, $rows[$i].Domain, $rows[$i].Role, $rows[$i].IPAddress) | Out-Null
    }
}

$numA.Add_ValueChanged({ Update-PreviewGrid })
$numB.Add_ValueChanged({ Update-PreviewGrid })
$numC.Add_ValueChanged({ Update-PreviewGrid })
$numPrefix.Add_ValueChanged({ Update-PreviewGrid })
$txtBaseIp.Add_TextChanged({ Update-PreviewGrid })
$txtGateway.Add_TextChanged({ Update-PreviewGrid })
$txtDns.Add_TextChanged({ Update-PreviewGrid })

Update-PreviewGrid

# ---------------------------------------------------------------------------
# Deploy / Cancel
# ---------------------------------------------------------------------------

$script:wizardResult = $null

$btnCancel.Add_Click({
    $form.Close()
})

$btnDeploy.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtPassword.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Administrator password cannot be empty.', 'WAD_env', 'OK', 'Warning') | Out-Null
        return
    }
    if ($txtBaseIp.Text -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        [System.Windows.Forms.MessageBox]::Show('Base IP address is not a valid IPv4 address.', 'WAD_env', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $txtSwitch.Text) {
        [System.Windows.Forms.MessageBox]::Show('Switch name cannot be empty.', 'WAD_env', 'OK', 'Warning') | Out-Null
        return
    }

    # Validate template files and auto-protect any that aren't read-only yet.
    $templateEntries = @(
        [PSCustomObject]@{ Label = 'Server 2022'; Path = $txtServer2022.Text.Trim() },
        [PSCustomObject]@{ Label = 'Windows 11';  Path = $txtClient11.Text.Trim() }
    )
    foreach ($entry in $templateEntries) {
        if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show(
                "$($entry.Label) template not found:`n$($entry.Path)`n`nUse Browse to point at the correct .vhdx file.",
                'WAD_env', 'OK', 'Warning') | Out-Null
            return
        }
        if (-not (Test-ParentImageProtected -Path $entry.Path)) {
            try {
                Protect-ParentImage -Path $entry.Path
                Write-Host "Auto-protected parent image: $($entry.Path)"
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Could not set $($entry.Label) template to read-only:`n$($entry.Path)`n`n$($_.Exception.Message)",
                    'WAD_env', 'OK', 'Error') | Out-Null
                return
            }
        }
    }

    $nameOverrides = @{}
    $ipOverrides = @{}
    foreach ($row in $grid.Rows) {
        $canonical = $row.Cells['Canonical'].Value
        $canonicalIp = $row.Cells['CanonicalIP'].Value
        $editedName = $row.Cells['Name'].Value
        $editedIp = $row.Cells['IPAddress'].Value
        if ($canonical -and $editedName -and $editedName -ne $canonical) {
            $nameOverrides[$canonical] = $editedName
        }
        if ($canonical -and $editedIp -and $editedIp -ne $canonicalIp) {
            $ipOverrides[$canonical] = $editedIp
        }
    }

    $script:wizardResult = [PSCustomObject]@{
        DomainAServerCount    = [int]$numA.Value
        DomainBServerCount    = [int]$numB.Value
        ClientCount           = [int]$numC.Value
        NetworkConfig         = [PSCustomObject]@{
            SubnetPrefixLength = [int]$numPrefix.Value
            Gateway            = $txtGateway.Text
            DnsServers         = @($txtDns.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            BaseIPAddress      = $txtBaseIp.Text
        }
        NameOverrides         = $nameOverrides
        IPOverrides           = $ipOverrides
        SwitchName            = $txtSwitch.Text
        ExternalAdapterName   = $cmbAdapter.Text
        VmStorageRoot         = $txtVmRoot.Text
        ParentImagePaths      = @{
            Server2022 = $txtServer2022.Text.Trim()
            Client11   = $txtClient11.Text.Trim()
        }
        AdministratorPassword = $txtPassword.Text
    }
    $form.Close()
})

[void]$form.ShowDialog()

if (-not $script:wizardResult) {
    Write-Host 'Cancelled - no deployment started.'
    return
}

$deployParams = @{
    DomainAServerCount    = $script:wizardResult.DomainAServerCount
    DomainBServerCount    = $script:wizardResult.DomainBServerCount
    ClientCount           = $script:wizardResult.ClientCount
    NetworkConfig         = $script:wizardResult.NetworkConfig
    NameOverrides         = $script:wizardResult.NameOverrides
    IPOverrides           = $script:wizardResult.IPOverrides
    SwitchName            = $script:wizardResult.SwitchName
    VmStorageRoot         = $script:wizardResult.VmStorageRoot
    ParentImagePaths      = $script:wizardResult.ParentImagePaths
    AdministratorPassword = $script:wizardResult.AdministratorPassword
}
if ($script:wizardResult.ExternalAdapterName) {
    $deployParams.ExternalAdapterName = $script:wizardResult.ExternalAdapterName
}

Write-Host "Starting deploy with $($deployParams.DomainAServerCount) Domain A server(s), $($deployParams.DomainBServerCount) Domain B server(s), $($deployParams.ClientCount) client(s)..."
& (Join-Path $PSScriptRoot 'Deploy.ps1') @deployParams
