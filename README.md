# AD Training Lab Deployment Scripts

Deploys a configurable Active Directory training lab on Hyper-V for hands-on
AD administration practice. The scripts build clean, networked, bare VMs and
stop **before** any AD configuration — DC promotion, DNS, DHCP, OUs, GPOs,
trusts, and user/group management are 100% the trainee's exercise.

The design rationale and eng-review decisions are baked into the code
comments throughout - read those before changing behavior, not just the
code itself.

## Using this on your own Hyper-V host (colleagues, other trainers)

This repo ships **scripts only — no Windows OS images**. That's deliberate,
not an oversight: a base VHDX is someone's sysprepped, licensed Windows
install, and redistributing that (even privately) raises licensing
questions this repo has no business answering for you. Bring your own:

1. Your own Windows Server 2022 + Windows 11 install media (eval or
   licensed) - see "One-time setup: base images" below for both the
   from-scratch and from-existing-template paths.
2. Your own reserved IP block - `Lib/VmDefinitions.psm1`'s network values
   are placeholders and will not work on your LAN as-is.
3. Your own external network adapter name for `-ExternalAdapterName` -
   run `Get-NetAdapter` on your host to find it.
4. Sign-off for bridged networking on your own network (see BLOCKING below)
   - this isn't transferable from someone else's approval.

Everything else - the topology, the safety checks, the test suite - works
as-is once those four are in place.

**Testing on a nested Hyper-V host (Hyper-V running inside VMware/VirtualBox,
not bare metal)?** This works but needs extra host-level setup the bare-metal
case doesn't: nested virtualization enabled on the outer VM, the outer
hypervisor's promiscuous-mode block worked around (on VMware Workstation on
Linux specifically, this usually means `/dev/vmnet*` permissions, not just
the per-VM `.vmx` setting), and enough RAM given to the outer VM for all 5
nested VMs simultaneously. `Deploy.ps1` already sets `MacAddressSpoofing On`
per VM for this case - that part needs no action from you. Expect this
environment to be flakier than bare metal (occasional slow boots, rare
unattend.xml misses) - that's the nesting, not a code bug.

## Topology

Counts per role are configurable (`Deploy.ps1 -DomainAServerCount`,
`-DomainBServerCount`, `-ClientCount`, or via the wizard - see below). The
defaults reproduce the original fixed 5-VM design:

| VM | Role | Domain | OS |
|----|------|--------|-----|
| DC1 | Domain controller (first) | corp.lab (Domain A) | Windows Server 2022 |
| DC2 | Domain controller (additional) | corp.lab (Domain A) | Windows Server 2022 |
| PDC1 | Domain controller (first) | partner.lab (Domain B) | Windows Server 2022 |
| CL1 | Client | corp.lab (Domain A) | Windows 11 |
| CL2 | Client | corp.lab (Domain A) | Windows 11 |

Domain A always has at least 1 DC (DC1 creates the forest; DC2+ are
additional DCs for redundancy/replication/FSMO-transfer practice within that
one domain). Domain B (PDC1, PDC2, ...) is a separate forest so the trainee
can establish and test a trust relationship with Domain A - set
`-DomainBServerCount 0` to skip it entirely if trust practice isn't needed.
The script only gets Domain B's DCs to a reachable, forest-ready state -
creating and testing the actual trust is trainee work. Clients (CL1, CL2,
...) all run Windows 11 - see the Client10 note below if you want to restore
mixed-fleet practice. Every generated hostname can be renamed via
`-NameOverrides` (or the wizard) - safe to do freely, since no AD DS role is
installed by this script.

Clients were meant to run different client OSes (Windows 10 + 11) for
mixed-fleet practice, but one specific Windows 10 template's checkpoint
merge hung reproducibly on the original author's host (see `TODOS.md`) —
all clients default to Windows 11 for now. The codebase fully supports a
`Client10` image (`Lib/ParentImage.psm1`'s `Get-ParentImagePath` already
handles it) - if your own Windows 10 source doesn't hit the same `Merge-VHD`
issue, building `Client10-Base.vhdx` and switching a client's `OSImage` back
in `Lib/VmDefinitions.psm1` should just work.

## BLOCKING — before you run anything

This design uses a **full bridged/external** Hyper-V switch — the lab VMs
sit on your real LAN so a trainee can RDP in from their own laptop. **Get
sign-off from whoever owns that network first.** If bridging isn't approved,
this design needs revisiting (fall back to a NAT-out/no-inbound switch) before
any of the steps below.

You'll also need to pick a real reserved IP block (5 static addresses,
outside your LAN's DHCP scope) and pass it via `Get-LabVmDefinitions
-NetworkConfig` — the values in `Lib/VmDefinitions.psm1` are **placeholders**
and must not be used as-is on a real network.

**Default Administrator password.** Every VM's Administrator account gets
the same known password (`TrainingLab@2026!` by default, in
`Lib/Unattend.psm1`'s `New-PerVmUnattendXml`) — this is deliberate, not a
leftover secret: the trainee needs a credential to RDP in and start their
exercise, and on a bridged-to-your-LAN network this password is real attack
surface. Override it via `-AdministratorPassword` before deploying anywhere
that isn't fully isolated/trusted.

## One-time setup: base images

**Storage location:** both the parent images and the per-VM differencing
disks default to `F:\WAD_env\...` when an `F:\` drive exists (falls back to
a path next to the scripts otherwise). Base images need real room — a
Windows Server install after sysprep is typically 15-20GB+ each — so make
sure whichever drive this resolves to actually has the space; the project's
own system drive may not (this was a real gap caught by actually running
`Deploy.ps1`, not just the unit tests).

Two parent VHDXs are needed: `Server2022-Base.vhdx`, `Client11-Base.vhdx`
(a third, `Client10-Base.vhdx`, is planned but currently blocked — see
`TODOS.md`). Two ways to get them:

**From scratch:**
1. Source ISOs: Windows Server 2022 and Windows 11 (evaluation or
   licensed). Confirm activation/licensing path — eval images expire around
   180 days.
2. Install each OS once in a throwaway VM, generalize with `sysprep
   /oobe /generalize /shutdown`, then place the resulting flat VHDX at the
   matching `F:\WAD_env\ParentImages\*-Base.vhdx` path above.

**From an existing sysprepped Hyper-V template (this lab's actual setup):**
If a template VM was checkpointed before/during its sysprepped install, its
real disk content sits in a `.avhdx` checkpoint file on top of a near-empty
base `.vhdx` — confirmed by inspecting the templates used here. `Merge-VHD`
merges a checkpoint into its EXISTING immediate parent in place (it does
NOT create a new file at an arbitrary destination — confirmed the hard way),
so merge first, then copy the now-flattened parent to the final path:
```powershell
Merge-VHD -Path 'F:\WAD_env\TemplateImport\TEMPLATE-SRV2022\TEMPLATE-SRV2022_<guid>.avhdx'
Copy-Item 'F:\WAD_env\TemplateImport\TEMPLATE-SRV2022\TEMPLATE-SRV2022.vhdx' `
          -Destination (Get-ParentImagePath -OSImage Server2022)
```
If the template has no checkpoint (a single flat `.vhdx` already, like the
Windows 11 template used here), just copy/move it directly to the matching
`*-Base.vhdx` path — no merge needed.

**A long merge needs to survive the session that launched it.** A non-interactive
SSH/exec session's child processes can get torn down when that session's
logon token is destroyed at disconnect, even if the process was started
"detached" (`Start-Process`). Running the merge as a one-time Windows
Scheduled Task instead (`schtasks /Create ... /SC ONCE`, no stored
credentials needed if you omit `/RU`/`/RP`) decouples it from any single
session — confirmed this is what actually fixed it after a plain detached
process kept dying silently.

**Protect each parent image** (do this for every image, every time you
rebuild one):
```powershell
Import-Module .\Lib\ParentImage.psm1
Initialize-ParentImageRoot
Protect-ParentImage -Path (Get-ParentImagePath -OSImage Server2022)
Protect-ParentImage -Path (Get-ParentImagePath -OSImage Client11)
```
`Deploy.ps1` refuses to run if any parent isn't read-only — this is what
stops a differencing-disk build from silently corrupting every VM at once
if a parent is ever touched.

## Running the lab

**GUI wizard (recommended for first-time/occasional use):**

```powershell
.\Start-LabDeployWizard.ps1
```

A dialog lets you tune VM counts per role, rename any generated VM, pick the
base IP/gateway/DNS, the sysprep template (parent image) folder, the
Hyper-V switch/adapter, VM storage location, and the Administrator
password - with a live preview of the resulting VM list - then runs
`Deploy.ps1` with those values in the same window. It's a pure convenience
layer: `Deploy.ps1` itself is untouched and still fully scriptable.

**Direct CLI (scripting, automation, headless use):**

```powershell
# First time: also need -ExternalAdapterName (run Get-NetAdapter to find candidates)
.\Deploy.ps1 -ExternalAdapterName 'Ethernet'

# Subsequent runs, once the switch exists:
.\Deploy.ps1

# Tune counts/names/IPs/template path without the GUI:
.\Deploy.ps1 -DomainAServerCount 3 -ClientCount 1 -ParentImageRoot 'D:\Templates' `
    -NameOverrides @{ DC1 = 'TRAINER-DC01' }
```

Reset to a clean state for the next trainee or attempt - pass the SAME
`-DomainAServerCount`/`-DomainBServerCount`/`-ClientCount`/`-NetworkConfig`/
`-NameOverrides`/`-IPOverrides` you deployed with, so it rebuilds the same VM
name list to reset (it doesn't discover live VMs by any other means):

```powershell
.\Reset.ps1
```

Both scripts write a timestamped log to `Logs\` and report differencing-disk
sizes after each reset, so disk growth across repeated cycles stays visible
(see `TODOS.md` for the related investigation item).

## Tests

Unit tests (pure logic, mocked Hyper-V calls — run anywhere PowerShell +
Pester is available):

```powershell
Invoke-Pester -Path .\Tests\VmDefinitions.Tests.ps1, .\Tests\ParentImage.Tests.ps1, .\Tests\Unattend.Tests.ps1, .\Tests\DiskBudget.Tests.ps1, .\Tests\Logging.Tests.ps1
```

Integration/E2E tests (build and tear down REAL VMs — run only on the actual
Hyper-V training host, after base images are built and protected):

```powershell
Invoke-Pester -Path .\Tests\DeployReset.E2E.Tests.ps1 -Tag RequiresHyperV
```

The E2E suite includes the **"v1 proven" gate**: 3 clean deploy→reset→deploy
cycles with no manual intervention, as one automated test run instead of
manual babysitting.

## Project layout

```
WAD_env/
├── Lib/
│   ├── VmDefinitions.psm1   # topology + pre-flight IP check
│   ├── ParentImage.psm1     # parent VHDX read-only protection
│   ├── Unattend.psm1        # per-VM unattend.xml + offline injection
│   ├── DiskBudget.psm1      # disk-space pre-flight + size reporting
│   └── Logging.psm1         # timestamped run logging
├── Deploy.ps1                # builds the lab
├── Reset.ps1                 # restores to 00-baseline or tears down
├── Start-LabDeployWizard.ps1 # GUI front-end for Deploy.ps1 (optional)
├── Tests/                    # Pester unit + E2E tests
├── ParentImages/             # protected base VHDXs (not committed)
├── VMs/                      # per-VM differencing disks (not committed)
├── Logs/                     # run logs (not committed)
└── TODOS.md                  # deferred low-confidence items from eng review
```

## Not in scope (v1)

DNS/DHCP scaffolding, trust pre-staging, multi-trainee concurrency,
automated grading of the trainee's AD work, and the snapshot "scenario tree"
(broken-trust/orphaned-FSMO checkpoints beyond `00-baseline`) are explicitly
deferred. These were each weighed against the design's actual goal (the
trainee configures AD by hand; the script only builds the starting point)
and cut deliberately, not for lack of time — see `TODOS.md` for anything
still tracked as a follow-up.
