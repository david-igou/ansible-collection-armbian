# Bootflow PXE-First Invariant — Design Spec

**Date:** 2026-05-07
**Status:** Drafted post hardware-debugging session that produced a working `BOARD=orangepi5pro` Armbian image with mainline U-Boot v2025.10.

## Problem

The v1 architecture spec (`docs/architecture.md`) claims:
> DHCP lease has no option assigned → PXE target falls through (no `next-server`), `bootflow scan` continues down the list, lands on mmc1's `boot.scr`, board boots local SD rootfs.

This is wrong on two counts, both surfaced empirically during the 2026-05-07 debugging session:

1. **U-Boot 2025.10's `bootflow` framework is not driven by `BOOT_TARGETS`/`boot_targets`.** The `armbian_build` role's userpatch (`pre_config_uboot_target__orangepi5pro_pxe_first`) sed-replaces `BOOT_TARGETS` in `include/configs/rockchip-common.h`, which feeds the legacy `distro_bootcmd` path. Modern U-Boot's `bootcmd=bootflow scan -lb` ignores that env var and iterates bootdevs in DT order with its own bootmeth ordering. So the patch is a no-op for boot ordering.

2. **U-Boot's PXE bootmeth ignores DHCP option 66 for `serverip` selection.** `serverip` is taken from BOOTP `siaddr` (RFC 951 next-server field) or, if `siaddr=0`, from the DHCP server's own IP via option 54. RouterOS option-66 was assumed to direct U-Boot to `tftp_server_ip=10.10.45.242` but is silently ignored. Verified with serial capture against `lease.dhcp-option-set=armbian-nfsroot` — TFTP requests went to the gateway/DHCP-server IP `10.10.9.1`, not `10.10.45.242`.

The combined effect: every cold boot of the `orangepi5pro` SD image hangs in TFTP retries against a server with no TFTP daemon (rb5009/`10.10.9.1`) until BL31's hardware watchdog resets the chip. Endless loop. The "PXE first, fall through to SD" invariant is not delivered.

## Constraint

The user's RouterOS configuration (network-level: `next-server`, `gateway`, `dns-server`, etc.) is managed in a separate codebase. This spec must not duplicate ownership of network-level RouterOS state — it should *depend* on the external repo setting `next-server` correctly, and surface a loud failure when it isn't.

## Goal

Restore the v1 invariant — PXE-first U-Boot with fast fall-through to SD when the lease isn't configured for netboot — by closing the gap between what the architecture doc claimed and what the hardware actually does. Keep the user-visible control surface (RouterOS lease's `dhcp-option-set` toggled by `enable_netboot.yml` / `disable_netboot.yml`) unchanged.

## Empirical findings

Three hardware experiments on 2026-05-07 (post-rebuild image, U-Boot 2025.10):

1. **Sentinel option 66 = `0.0.0.0` test.** Created RouterOS option-set `armbian-no-pxe` containing only option 66 = `0.0.0.0`, assigned to opi5pro-01's lease. Power-cycled, captured serial. Result: U-Boot ignored option 66 entirely; TFTP source was `10.10.9.1` (the DHCP server) — same as with no option-set assigned. **Approach A (sentinel option 66) does not work.**

2. **`armbian-nfsroot` option-set assigned + `pxelinux.cfg/01-MAC` with `LOCALBOOT 0` test.** Set lease's `dhcp-option-set=armbian-nfsroot` (option 66 → `10.10.45.242`). Power-cycled. Result: U-Boot still TFTP'd from `10.10.9.1` despite option 66 being correctly delivered. **Confirms U-Boot 2025.10 bootmeth-pxe ignores option 66 for serverip selection.**

3. **Network-level `next-server=10.10.45.242` on vlan9 test.** Set RouterOS network's `next-server` to the netboot.xyz container's IP. Power-cycled with an empty `pxelinux.cfg/` directory. Result:
   - U-Boot's PXE bootmeth correctly TFTP'd from `10.10.45.242` (siaddr → serverip).
   - All fallback files (`01-MAC`, `0A0A0919`, ..., `default`) returned 404 in ~1 s each.
   - Bootflow aborted the network bootdev after the chain, scanned `mmc@fe2c0000.bootdev`, found `boot.scr`, kernel booted from SD.
   - Total time from PoE-on to "Starting kernel" ≈ 30 s (5 × DHCP retry + ~10 s of TFTP 404s + MMC scan + kernel start).

Experiment 3 is what the design rests on. Serial transcripts saved at `/tmp/exp-localboot2.log` on the dev host (not committed).

## Design

A single network-level RouterOS knob — `next-server` on the SBC network — is the missing piece. With it in place, U-Boot's existing PXE bootmeth Just Works: it TFTPs from the netboot.xyz container, finds (or doesn't find) a per-board `pxelinux.cfg/01-<MAC>`, and the existing toggle behaviour of `enable_netboot.yml` / `disable_netboot.yml` produces the intended PXE/SD switch.

The collection does not write this knob — the user's separate RouterOS-config repo owns it. The collection's role is to *assert* the knob is correct before any play that depends on it, with a remediation message naming the exact RouterOS command to run.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ RouterOS-config repo (out of scope for this collection)          │
│   sets:  /ip dhcp-server network set [find address=<sbc-net>]    │
│            next-server=<tftp_server_ip>                          │
└──────────────────────────────────────────────────────────────────┘
                          ▲
                          │ documented prerequisite
                          │
┌──────────────────────────────────────────────────────────────────┐
│ This collection                                                  │
│                                                                  │
│ - setup_routeros_dhcp.yml  ─┐ preflight assert: next-server is   │
│ - enable_netboot.yml        │ correct on the SBC network. Fail   │
│ - disable_netboot.yml       │ fast w/ remediation cmd if not.    │
│ - stage_netboot_assets.yml ─┘                                     │
│                                                                  │
│ - enable_netboot:    write per-board pxelinux.cfg/01-<MAC>       │
│                      assign dhcp-option-set on lease             │
│ - disable_netboot:   remove per-board pxelinux.cfg/01-<MAC>      │
│                      clear dhcp-option-set on lease              │
└──────────────────────────────────────────────────────────────────┘
```

### Components

**Add: `roles/routeros_dhcp/tasks/preflight_next_server.yml`** (new task file). Reads the SBC network's current `next-server` value via `community.routeros.command` `print as-value` and asserts it matches `tftp_server_ip`. Loud fail message includes the exact `set` command the user can paste into their RouterOS-config repo.

**Add: `roles/routeros_dhcp/defaults/main.yml`** — new variable `routeros_sbc_network_address: ""` (CIDR, e.g. `"10.10.9.0/24"`). Inventory must set it; preflight asserts it's non-empty.

**Modify: `playbooks/setup_routeros_dhcp.yml`** — include the new preflight task before the existing option-set creation.

**Modify: `playbooks/enable_netboot.yml`, `playbooks/disable_netboot.yml`, `playbooks/stage_netboot_assets.yml`** — include the same preflight at the top of each play. Cheap, idempotent, catches misconfiguration before per-host work.

**Modify: `roles/routeros_dhcp/tasks/disable_netboot.yml`** — extend to also delete the per-board `pxelinux.cfg/01-<MAC>` on the netboot server. Today it only clears the lease's option-set; with the new design, the file presence/absence is what determines mode (option-set assignment becomes documentation/double-signal, not the active lever). Symmetric with `enable_netboot.yml` writing the file.

**Modify: `docs/architecture.md`** — replace the wrong "no `next-server`" wording. New text describes the actual mechanism: `next-server` is a documented RouterOS prerequisite owned externally; this collection's per-board `pxelinux.cfg` presence on the netboot server determines mode; U-Boot's bootflow falls through fast (404 chain) when no per-board config exists.

**Not changed:**
- `roles/armbian_build/*` — no U-Boot patches needed; the `BOOT_TARGETS` userpatch is now a no-op but harmless. Documenting this in the role's README is in scope; removing the patch is out of scope (a separate cleanup).
- `roles/routeros_dhcp/tasks/setup_options.yml` — option 66 / option-set definitions stay as-is. They're now ornamental (U-Boot ignores option 66, and the option-set's signal is duplicated by file presence) but harmless.
- `roles/routeros_dhcp/templates/pxelinux_cfg.j2` — content unchanged.
- `roles/netboot_assets/*` — unaffected.
- The `armbian-reprovision*` RouterOS objects — already orphan; their cleanup is separately tracked in the post-rebuild followups plan.

### Data flow

Cold boot, netboot disabled:
1. PoE on → SPL → BL31 → U-Boot 2025.10.
2. autoboot countdown (1 s) → `bootcmd=bootflow scan -lb`.
3. `efi_mgr` bootmeth: no EFI partition, fails fast.
4. `eth_eqos#0.bootdev`: DHCPDISCOVER → DHCPOFFER (siaddr=10.10.45.242 from network's next-server) → DHCPACK.
5. PXE bootmeth: TFTPs `pxelinux.cfg/01-<MAC>` from 10.10.45.242 → 404 (file not written by `disable_netboot.yml`).
6. Fallback chain (`0A0A0919`, `0A0A091`, ..., `default-arm-rk3588-evb_rk3588`, ..., `default`): each returns 404 in ~1 s.
7. Bootflow aborts the network bootdev (~5–10 s total since step 4).
8. `mmc@fe2c0000.bootdev`: finds `boot.scr` on SD partition 1, runs it, kernel boots from local rootfs.

Cold boot, netboot enabled:
1. Same as above through step 4.
2. PXE bootmeth: TFTPs `pxelinux.cfg/01-<MAC>` from 10.10.45.242 → 200, file content is the per-board NFS-root config from `pxelinux_cfg.j2`.
3. U-Boot parses `KERNEL`, `INITRD`, `FDT`, `APPEND`, fetches each via TFTP, then `booti` with `root=/dev/nfs nfsroot=...`.
4. Kernel boots NFS root.

### Error handling

- **`next-server` not set / wrong value:** preflight asserts before any per-host work runs. Fail message includes the remediation command verbatim. No silent failure.
- **TFTP server unreachable:** U-Boot's BOOTP retries 5×; bootflow then aborts the network bootdev and falls through to MMC. Same path as the missing-file case; ~30 s additional cold-boot delay; not catastrophic.
- **`pxelinux.cfg` exists but malformed:** U-Boot logs parse error, bootmeth aborts, bootflow falls through to MMC. Operator-visible only via `test_hardware_e2e.yml` or serial.
- **Mode-state asymmetry** (option-set assigned but file missing, or vice versa): with the design's `disable_netboot` extension, `enable_netboot` and `disable_netboot` both write *and* toggle the option-set, so they always leave a coherent pair. Pre-existing leases with one but not the other become possible only via manual operator edits — outside the design's threat model.

### Testing

This repo has no formal unit test suite for role behaviour. The closest harness is `playbooks/test_hardware_e2e.yml`, which cycles a board through SD → NFS → SD and asserts each transition.

- The new preflight task's success path is exercised by every play that includes it; its failure path is best verified by running with `routeros_sbc_network_address: "0.0.0.0/0"` (an obviously-wrong CIDR) and confirming the assert fires before any per-host work runs.
- `test_hardware_e2e.yml` should pass end-to-end on the new image once `next-server` is set on vlan9 (it would have hung the same way the cold boot hung, before this design). Add a single new pre-flight phase that explicitly asserts the next-server precondition; any operator running the test gets a useful failure message instead of a silent timeout.
- Molecule: existing `default` scenario covers the role's RouterOS interaction shape; the new preflight is structurally identical to other `community.routeros.command` + `assert` pairs in this codebase. No new molecule scenario.

## Out of scope

- Removing the `armbian_build` role's `BOOT_TARGETS` userpatch. It's now confirmed inert (modern bootflow ignores it) but is harmless and removing it is a separate, low-priority cleanup.
- Removing orphan RouterOS objects (`armbian-reprovision*`) — already tracked in `2026-05-07-post-rebuild-followups.md`.
- Restoring per-board NFS-root boot to a working state on the new image. The design assumes the existing `pxelinux_cfg.j2` content + TFTP-served `armbian/<board>/{vmlinuz,initrd,dtb}` work correctly when reached. We've verified U-Boot reaches the right TFTP server; we have not verified an end-to-end NFS-root boot since the existing `stage_netboot_assets.yml` machinery hasn't been rerun against this image. Validating that is the *implementation plan's* responsibility, not this design's.
- Changing the `routeros_dhcp` role's `setup_options.yml` to drop the now-ornamental option 66 / option-set definitions. Pre-existing state; can be cleaned up later if desired.

## Open question (escalated to implementation plan)

The existing pxelinux.cfg template (`pxelinux_cfg.j2`) generates a config that references `KERNEL armbian/{{ board_model }}/vmlinuz` etc. — TFTP-relative paths that the netboot.xyz container's TFTP daemon resolves against `/config/menus/`. This was working in the previous orangepi5 image's flow (per architecture.md history). The design doesn't change the template. Whether the existing TFTP layout serves the kernel/initrd/dtb files correctly to the new orangepi5pro image is a question the implementation plan's hardware-test step must answer.
