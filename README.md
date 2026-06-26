# AD Training Lab — Hyper-V Deployment Scripts

Deploys a configurable Active Directory training lab on Hyper-V. The scripts
build clean, networked, bare VMs and stop **before** any AD configuration —
DC promotion, DNS, DHCP, OUs, GPOs, trusts, and user/group management are
100% the trainee's exercise.

---

## Getting the scripts

**Option A — Git (recommended):**

```powershell
git clone https://github.com/bygyz/WAD_env.git
cd WAD_env
```

**Option B — ZIP download (no Git required):**

```powershell
Invoke-WebRequest -Uri https://github.com/bygyz/WAD_env/archive/refs/heads/master.zip `
                  -OutFile "$env:USERPROFILE\Downloads\WAD_env.zip"
Expand-Archive -Path "$env:USERPROFILE\Downloads\WAD_env.zip" `
               -DestinationPath "$env:USERPROFILE\Downloads\WAD_env"
cd "$env:USERPROFILE\Downloads\WAD_env\WAD_env-master"
```

---

## Prerequisites

Before running anything, you need four things:

1. **A Hyper-V host** (bare metal or nested — see nested notes below)
2. **Windows OS images** — this repo ships scripts only, no VHDXs (see
   [One-time setup: base images](#one-time-setup-base-images))
3. **A bridged network adapter** and sign-off from whoever owns your LAN
   (see [Networking](#networking--blocking))
4. **An IP block reserved outside your LAN's DHCP scope** — 5 static
   addresses. You set these in the wizard or CLI at deploy time; the defaults
   in `Lib/VmDefinitions.psm1` are placeholders only.

---

## Quick start

**First run — use the wizard:**

```powershell
.\Start-LabDeployWizard.ps1
```

The wizard lets you configure everything through a GUI: VM counts, hostnames,
IPs/gateway/DNS, parent image folder, Hyper-V switch/adapter, storage path,
and Administrator password. It shows a live preview of the resulting VM list,
then runs `Deploy.ps1` for you.

**Reset for the next trainee:**

```powershell
.\Reset.ps1
```

Pass the same flags you used at deploy time so it rebuilds the correct VM list.

---

## Networking — BLOCKING

This lab uses a **bridged (external) Hyper-V switch** so trainees can RDP in
from their own laptops. **Get sign-off from whoever owns the network before
deploying.** If bridging isn't approved, the design needs revisiting (NAT-out
switch) before any of the steps below apply.

You'll need a block of 5 static IPs outside your LAN's DHCP scope. Set them
in the wizard's network fields (or via `-NetworkConfig` on the CLI) — do not
leave the placeholder values from `Lib/VmDefinitions.psm1` in place on a
real network.

**Administrator password.** Every VM's `Administrator` account gets the same
password (`TrainingLab@2026!` by default in `Lib/Unattend.psm1`). This is
intentional — the trainee needs a credential to log in — but it is real attack
surface on a bridged LAN. Override it with `-AdministratorPassword` before
deploying anywhere that isn't fully isolated.

---

## Lab topology

Counts per role are configurable via the wizard or CLI flags. Defaults
reproduce the original 5-VM design:

| VM   | Role                          | Domain              | OS                  |
|------|-------------------------------|---------------------|---------------------|
| DC1  | Domain controller (primary)   | corp.lab (Domain A) | Windows Server 2022 |
| DC2  | Domain controller (additional)| corp.lab (Domain A) | Windows Server 2022 |
| PDC1 | Domain controller (primary)   | partner.lab (Domain B) | Windows Server 2022 |
| CL1  | Client                        | corp.lab (Domain A) | Windows 11          |
| CL2  | Client                        | corp.lab (Domain A) | Windows 11          |

- **Domain A** always has at least 1 DC. Additional DCs (DC2, DC3, ...) are
  for redundancy/replication/FSMO-transfer practice within the same forest.
- **Domain B** (PDC1, PDC2, ...) is a separate forest for trust relationship
  practice. Set `-DomainBServerCount 0` to skip it.
- **Hostnames** can be renamed via `-NameOverrides` or the wizard — safe to
  do freely since no AD DS role is installed by these scripts.
- **Windows 10 clients** are currently disabled (a checkpoint merge hang on
  the original host — see `TODOS.md`). All clients default to Windows 11.
  The codebase fully supports a `Client10` image if your environment doesn't
  hit the same issue.

---

## One-time setup: base images

Two parent VHDXs are required: `Server2022-Base.vhdx` and `Client11-Base.vhdx`.
They default to `F:\WAD_env\ParentImages\` (falls back to a path next to the
scripts if `F:\` doesn't exist). Base images need 15–20 GB+ each — confirm
the target drive has the space.

### Option A — Download from OneDrive (easiest)

If you already have sysprepped VHDXs stored on your personal OneDrive:

1. Launch the wizard: `.\Start-LabDeployWizard.ps1`
2. In the *Host & security* section, click **From OneDrive...** next to the
   *Server 2022 image* field.
3. Paste your OneDrive sharing link (the URL from "Copy link" in OneDrive)
   and click **Download**. The transfer runs via BITS — progress is visible
   in the console behind the form. For a 15–20 GB image expect 10–20 minutes
   depending on your connection.
4. Repeat for the *Windows 11 image* field.
5. Click **Deploy** — the wizard auto-protects the downloaded files and
   proceeds normally.

> The download saves to whatever path is shown in the image textbox. Change
> that path before clicking "From OneDrive..." if you want the file elsewhere.

### Option B — From scratch

1. Get Windows Server 2022 and Windows 11 ISOs (evaluation or licensed).
   Eval images expire around 180 days — confirm your activation path.
2. Install each OS in a throwaway VM, then generalize:
   ```powershell
   sysprep /oobe /generalize /shutdown
   ```
3. Place the resulting flat VHDX at the matching `*-Base.vhdx` path.

### Option C — From an existing sysprepped template

**Flat `.vhdx` (no checkpoint):** launch the wizard and browse to the file
directly in the *Server 2022 image* or *Windows 11 image* fields. No copy,
no rename needed. The wizard sets the file read-only automatically before
deploying.

**Template with a checkpoint (`.avhdx` on top of a base `.vhdx`):** the real
disk content lives in the `.avhdx`. `Merge-VHD` merges it into its existing
immediate parent in place — it does NOT create a new file at an arbitrary
path (confirmed the hard way). Merge first, then browse to the result in the
wizard:

```powershell
Merge-VHD -Path 'F:\WAD_env\TemplateImport\TEMPLATE-SRV2022\TEMPLATE-SRV2022_<guid>.avhdx'
# then browse to TEMPLATE-SRV2022.vhdx in the wizard's Server 2022 image field
```

> **Keep a long merge alive.** A non-interactive session's child processes can
> be torn down at disconnect even when started "detached". Run the merge as a
> one-time Scheduled Task to decouple it from your session:
> ```powershell
> schtasks /Create /TN "MergeVHD" /SC ONCE /ST 00:00 /TR "powershell Merge-VHD -Path '...'"
> ```

### Protect the parent images

**Using the wizard:** protection is automatic — no manual step needed.

**Using `Deploy.ps1` directly (CLI):** protect each image before the first
deploy, and again any time you rebuild one:

```powershell
Import-Module .\Lib\ParentImage.psm1
Protect-ParentImage -Path 'F:\path\to\Server2022-template.vhdx'
Protect-ParentImage -Path 'F:\path\to\Client11-template.vhdx'
```

`Deploy.ps1` refuses to run against an unprotected parent — this stops a
differencing-disk build from silently corrupting every VM if a parent is
ever modified.

---

## Running the lab

### GUI wizard (recommended)

```powershell
.\Start-LabDeployWizard.ps1
```

Covers everything: VM counts, hostnames, IPs, adapter, storage, template
files, password. For each template you can either **Browse** to a local
`.vhdx` file or click **From OneDrive...** to paste a sharing link and
download it in-place. Runs `Deploy.ps1` directly when you click Deploy.

### CLI (scripting / headless)

```powershell
# First run: specify your external adapter name (find it with Get-NetAdapter)
.\Deploy.ps1 -ExternalAdapterName 'Ethernet'

# Subsequent runs (switch already exists):
.\Deploy.ps1

# Customize counts, names, IPs, template path:
.\Deploy.ps1 -DomainAServerCount 3 -ClientCount 1 -ParentImageRoot 'D:\Templates' `
    -NameOverrides @{ DC1 = 'TRAINER-DC01' }
```

### Reset

```powershell
.\Reset.ps1
```

Pass the same flags used at deploy time (`-DomainAServerCount`, `-ClientCount`,
`-NameOverrides`, etc.) so it rebuilds the correct VM name list to tear down.

Both scripts write a timestamped log to `Logs\` and report differencing-disk
sizes after each reset.

---

## Nested Hyper-V (Hyper-V inside VMware / VirtualBox)

This works but requires extra setup the bare-metal case doesn't:

- **Nested virtualization** enabled on the outer VM
- **Promiscuous mode** unblocked at the hypervisor level (on VMware Workstation
  on Linux this usually means `/dev/vmnet*` permissions, not just the per-VM
  `.vmx` setting)
- **Enough RAM** on the outer VM for all 5 nested VMs simultaneously

`Deploy.ps1` already sets `MacAddressSpoofing On` per VM — no action needed
on your part for that. Expect occasional slow boots or rare unattend.xml misses;
that's the nesting overhead, not a code bug.

---

## Tests

**Unit tests** (mocked Hyper-V, run anywhere PowerShell + Pester is available):

```powershell
Invoke-Pester -Path .\Tests\VmDefinitions.Tests.ps1, .\Tests\ParentImage.Tests.ps1, `
    .\Tests\Unattend.Tests.ps1, .\Tests\DiskBudget.Tests.ps1, .\Tests\Logging.Tests.ps1, `
    .\Tests\OneDriveDownload.Tests.ps1
```

**E2E tests** (builds and tears down real VMs — run only on the actual Hyper-V host,
after base images are built and protected):

```powershell
Invoke-Pester -Path .\Tests\DeployReset.E2E.Tests.ps1 -Tag RequiresHyperV
```

The E2E suite includes a **"v1 proven" gate**: 3 clean deploy→reset→deploy
cycles with no manual intervention, as one automated test run.

---

## Project layout

```
WAD_env/
├── Lib/
│   ├── VmDefinitions.psm1      # topology + network config + pre-flight IP check
│   ├── ParentImage.psm1        # parent VHDX read-only protection
│   ├── Unattend.psm1           # per-VM unattend.xml generation + offline injection
│   ├── OneDriveDownload.psm1   # OneDrive sharing-link → BITS download
│   ├── DiskBudget.psm1         # disk-space pre-flight + size reporting
│   └── Logging.psm1            # timestamped run logging
├── Deploy.ps1                 # builds the lab
├── Reset.ps1                  # restores to 00-baseline or tears down
├── Start-LabDeployWizard.ps1  # GUI front-end (optional)
├── Tests/                     # Pester unit + E2E tests
├── ParentImages/              # protected base VHDXs (not committed)
├── VMs/                       # per-VM differencing disks (not committed)
├── Logs/                      # run logs (not committed)
└── TODOS.md                   # deferred items from eng review
```

---

## Out of scope (v1)

DNS/DHCP scaffolding, trust pre-staging, multi-trainee concurrency, automated
grading, and snapshot scenario trees are deliberately deferred — see `TODOS.md`.
