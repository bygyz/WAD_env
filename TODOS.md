# TODOS

## AD Training Lab

### Verify host-side state doesn't leak beyond VM checkpoint revert

**What:** Confirm that resetting a VM via checkpoint restore actually clears all AD-related state, with no leakage into host-side or LAN infrastructure (DHCP leases, upstream DNS caching).

**Why:** Raised by the eng-review outside voice as a category risk for "is reset actually clean." On inspection it's low-confidence for this specific design — static IPs are used (no DHCP lease involved for the lab VMs), and nothing in the design describes DNS forwarding/delegation between the lab's own AD DNS zones and the corporate DNS server. Still worth a real check rather than leaving it as speculation.

**Context:** Confirm during the first real deploy→reset→deploy cycle (the "v1 proven" 3x test) — check whether anything outside the 5 VMs' own virtual disks changes across a reset. If genuinely nothing leaks, close this out; if something does, scope the fix then.

**Effort:** S
**Priority:** P3
**Depends on:** None — can be checked anytime once the deploy/reset scripts exist.

### Fix or replace the unusable TEMPLATE-CLI10 checkpoint merge

**What:** `Merge-VHD` on the TEMPLATE-CLI10 template's checkpoint (`TEMPLATE-CLI10_5448DA76-75DD-4948-BAEF-C3822E2483E5.avhdx`, ~11.45GB) hangs indefinitely with zero progress (confirmed: CPU and file size both completely flatlined across 5+ minute windows, twice, in two separate fresh PowerShell processes). The structurally identical TEMPLATE-SRV2022 checkpoint (~10.3GB) merged successfully in ~8 minutes on the same host right before this, so it's not a generic Merge-VHD/Hyper-V capability problem on this machine - something specific to this one checkpoint file.

**Why:** CL1 and CL2 were meant to run different client OSes (Windows 10 + Windows 11) for mixed-fleet AD admin practice. Without a working Client10 base image, both clients now run Windows 11 (`Lib/VmDefinitions.psm1`) - a working but less realistic substitute.

**Context:** Ruled out during diagnosis: stale file locks from killed prior attempts (cleared, didn't help), a stuck `vmms` service (restarted, confirmed healthy via fast `Get-VM` response, didn't help), Windows sleep/power management interrupting the process (disabled, didn't help), and process-reuse-after-one-large-merge (ran CLI10 in a completely fresh process, still hung identically). What's NOT yet tried: opening the file in an interactive Hyper-V Manager/console session on the VM directly (might surface a hidden prompt/dialog a non-interactive SSH/scheduled-task session can't see), `Test-VHD` or similar integrity check on the avhdx itself, or just re-exporting the Windows 10 template fresh from its original source VM.

**Effort:** M (diagnosis already ruled out the easy causes; next steps need console access)
**Priority:** P2
**Depends on:** Console/RDP access to the VM for interactive debugging - not resolvable over a non-interactive SSH session.

### Client11 (Windows 11) template was never properly left ready for specialize

**What:** Confirmed via a real deploy run (2026-06-25): CL1 boots successfully but never applies its unattend.xml at all - `C:\Windows\Panther\setupact.log` on the differencing disk shows no activity past `26/10/2023`, the date the parent template was originally built. The offline registry confirms why: `HKLM\SYSTEM\Setup\SystemSetupInProgress` and `OOBEInProgress` are both `0`, meaning Windows considers setup fully complete with nothing pending - it boots straight into the already-specialized 2023 state every time, regardless of what's in the injected unattend.xml. (Interesting: the same hive has `RespecializeCmdLine: Sysprep\sysprep.exe /respecialize /quiet` registered, suggesting this image may have been built via a provisioning flow that expects something else to trigger respecialization explicitly, rather than the standard `sysprep /generalize /oobe /shutdown` flow the Server2022 template clearly went through - that one's specialize pass runs correctly on every differencing disk.)

**Why:** This is the second of the two original client templates to turn out unusable (see the TEMPLATE-CLI10 entry above) - meaning neither original client template works as a base image for this lab as-is.

**Context:** Not fixable in this repo's code - `Deploy.ps1`/`Unattend.psm1` are working correctly (confirmed: the unattend.xml is injected with the right content every time, and the *exact same* code path runs DC1/DC2/DC3 successfully on the Server2022 template in the same deploy run). The fix has to happen at the template level: re-sysprep the Client11 source VM properly with `sysprep /generalize /oobe /shutdown` before recapturing it as the parent VHDX, or build a fresh Windows 11 template from scratch per the README's "from-scratch" path instead of reusing this particular existing one.

**Effort:** M (needs a working Windows 11 install to re-sysprep or rebuild from scratch - not a code change)
**Priority:** P1 (blocks both client VMs, CL1 and CL2, from ever getting their static IP/hostname/RDP config)
**Depends on:** Access to re-sysprep the existing Client11 VM correctly, or a fresh Windows 11 ISO to build a new template via the from-scratch path.

### Handle stale ARP/NetBIOS cache on full VM recreation

**What:** If a VM is ever fully recreated (not just checkpoint-restored) — e.g. recovering from disk corruption, or standing up a brand-new training cohort from scratch — handle stale ARP/NetBIOS cache entries on the real LAN from the old VM's MAC address.

**Why:** A recreated VM gets a new Hyper-V-generated MAC address but reuses the same static IP/hostname (per the fixed DC1/DC2/DC3/CL1/CL2 convention). Neighboring devices or switches on the bridged LAN can hold a stale cache entry pointing at the old MAC for a window of time, causing intermittent connectivity confusion right after a rebuild.

**Context:** Raised by the eng-review outside voice. Doesn't apply to the normal Restore-VMCheckpoint reset path used in v1 — only matters if/when VM-recreation tooling (vs. checkpoint-based reset) gets built, which isn't planned yet. Relevant to the "reused across many cohorts" goal in the design doc's Distribution Plan.

**Effort:** S
**Priority:** P4
**Depends on:** VM-recreation tooling existing in the first place (not yet planned).
