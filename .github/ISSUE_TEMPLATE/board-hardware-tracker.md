---
name: Board hardware tracker
about: Track hardware/firmware reliability issues specific to a single SBC model
title: "[board-tracker] <board-model>: hardware reliability"
labels: ["hardware", "board-tracker"]
---

<!--
  One issue per board model. Append new issues to "Issues observed" as
  they're discovered; do not open a new GitHub issue per failure mode.
  Update "Status" lines as the board hardens or workarounds land.

  ARM SBCs vary in ways that don't show up until you touch the hardware.
  This issue is the durable home for those findings — the next person
  onboarding this board (or hitting a familiar serial signature on a
  related board) should be able to grep this issue and skip the rediscovery.
-->

## Board

- **Model**: <e.g. orange-pi-5-pro>
- **Vendor**: <Xunlong, Radxa, etc.>
- **SoC**: <RK3588S, RK3566, A64, ...>
- **Armbian support tier**: <standard | community | wip>
- **Armbian config (`config/boards/<x>.conf`)**: <link>
- **First onboarded in this collection**: <YYYY-MM-DD, PR #N>

## Tested hardware/firmware versions

| Date | Image (.img.xz filename) | Kernel | U-Boot version line |
|---|---|---|---|
| YYYY-MM-DD | Armbian-... | x.y.z-current-... | U-Boot 2025.10_armbian-... |

## Issues observed

<!--
  For each distinct failure mode, copy this stanza. Keep serial signatures
  as literal copy-paste from /tmp/serial.log or socat capture; future
  greps will find them. "Frequency" is rough — "1 in N cold boots", "every
  power cycle after N min idle", etc. — but write what you have.
-->

### <Short name, e.g. "SD voltage select stuck">

**Symptom (one line)**:

**Serial signature**:
```
<paste literal output, including surrounding context lines>
```

**Frequency**: <e.g. ~1 in 5 cold cycles; clusters when board is cold; never seen warm>

**Trigger conditions**: <PoE cycle drain time, SD card vendor/class, kernel version, etc.>

**Impact**: <which playbook phases / e2e tasks fail; whether it manifests as silent fall-through or hard hang>

**Confused-with signatures** (false friends — looks similar but different cause): <e.g. "looks like the BOOTP-loop hardware flake but reaches rb5009; if /interface/bridge/host/print on the upstream switch DOES show the MAC, it's a software bug not this">

**Workaround in this collection**: <link to commit/role/variable, or "none — operator-side only">

**Workaround manual**: <e.g. "longer PoE drain (-e armbian_netboot_poe_cycle_delay=20-30) helps", "physically reseat SD card">

**Upstream / hardware tracking**: <links to Armbian forum, Rockchip BSP issues, vendor support tickets>

**Status**: <Open | Mitigated in collection | Resolved upstream | Hardware-replace-only>

---

## Software workarounds active in this collection

<!--
  Concrete pointers — file paths or commit shas — for what already runs
  to keep this board reliable. Update when adding new mitigations.
-->

- <e.g. `roles/netboot_assets/tasks/stage_rb5009.yml` always force-removes
  rb5009 vmlinuz before net_put — guards against the kernel/module
  version-mismatch class of mount-time failure>
- <e.g. `playbooks/test_hardware_e2e.yml` `_wait_timeout: 300` — chosen
  to absorb U-Boot's PXE → EFI → MMC fall-through on cold boots>

## Resolution checklist

- [ ] All listed issues investigated (root cause known, not just symptom mitigated)
- [ ] Each issue has either an upstream link, a software workaround, or a known hardware-replace path
- [ ] No collection task silently produces wrong state when these hardware modes fire
- [ ] Future operator hitting one of these signatures can find this issue from a `git grep` on the serial string
