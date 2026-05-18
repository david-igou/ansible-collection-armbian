# Local-Kernel Boot Mode for OPi5Max — Design

**Status**: Phase 1 + Phase 2 implemented and **hardware-proven autonomous** (LK2). Build hook `__999_orangepi5max_localcmd` bakes the Approach B `localcmd` into the U-Boot binary; a cold PoE cycle on opi5max-01 reaches a logged-in NVMe-rooted Linux in ~32s with zero UART intervention. LK1 (manual) and LK2 (autonomous) evidence on tracker [#81](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/81). #78's strategic kernel-update test deferred to LK3.
**Author**: David Igou.
**Date**: 2026-05-17.
**Tracking**: cross-links to [#78](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/78) (kernel updates); OPi5Max board-tracker (per LK1 evidence).

## Background

Today every onboarded board PXE-boots from rb5009 and runs a kernel/initrd/dtb served from TFTP. Three labels exist in pxelinux.cfg — `nfs`, `sd`, `local` — and they all load the **same** TFTP-served kernel/initrd/dtb. Only `append root=...` differs. The "passthrough" `local` mode means: kernel comes from TFTP, rootfs lives on NVMe.

Consequence: kernel updates are centrally owned. Bumping a kernel means rebuilding the image on the builder, refreshing TFTP files on rb5009, and (per [#78](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/78)) re-rsyncing `/lib/modules/<ver>/` into every NFS clone and every local-disk rootfs. Boards never run `apt upgrade linux-image-*` as the source of truth.

The goal of this design is to add a fourth boot mode in which **U-Boot loads the kernel/initrd/dtb directly off the NVMe**, via Armbian's pre-existing `/boot/extlinux/extlinux.conf` mechanism. The board owns its own kernel; rb5009 only serves the pxelinux.cfg that selects the mode.

## Goals / non-goals

**Goals (v1)**
- Add a `local_kernel` pxelinux label that hands off to a local-disk extlinux boot.
- Bring the mode up on `orange-pi-5-max-01` end-to-end and prove the kernel actually comes off NVMe (UART log + `/proc/cmdline` evidence).
- Keep the always-netboot invariant intact — pxelinux.cfg always present on rb5009; PXE-first ordering unchanged.
- Make the new mode renderable + validatable in `pxelinux_render`, verifiable in `board_boot_verify`, and selectable via `armbian_netboot_boot_mode: local_kernel`.

**Non-goals (v1)**
- Generalize to other boards. Per-board U-Boot defconfigs vary in env storage; rolling this out wider requires per-board verification. OPi5Max-first; document what generalization needs.
- Persistable U-Boot env on OPi5Max. The board ships `CONFIG_ENV_IS_NOWHERE=y` (volatile env); v1 bakes `localcmd` into the U-Boot binary's compile-time default environment via the existing image_build userpatches mechanism. Changing `localcmd` requires a rebuild.
- Hardware E2E test integration (`test_hardware_e2e.yml`). Manual UART validation suffices in v1.
- Auto-revert on local-kernel boot failure. Operator flips `armbian_netboot_boot_mode` back to `nfs` and re-runs `converge_boot_mode.yml`.
- Cross-link with #78's kernel-update automation. That work pre-empts the rb5009-driven flow; this mode just opens the door for it.

## Design

### Boot model

PXE-first ordering and pxelinux.cfg-as-selector are unchanged. The new label looks like:

```
label local_kernel
  menu label Boot local kernel from NVMe ({{ hostname }})
  localboot 0
```

Per [U-Boot's pxelinux docs](https://docs.u-boot.org/en/stable/usage/pxe.html), `localboot <flag>` runs whatever is in the `localcmd` environment variable; the flag is ignored. So everything hinges on what `localcmd` does.

For OPi5Max we bake the following into the U-Boot binary's compile-time default environment (Approach B, per the LK1 revision below):

```
localcmd=setenv bootargs root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console=ttyS2,1500000n8;
         nvme scan;
         ext4load nvme 0:4 ${kernel_addr_r} /boot/Image;
         ext4load nvme 0:4 ${ramdisk_addr_r} /boot/uInitrd;
         setenv ramdisk_size ${filesize};
         ext4load nvme 0:4 ${fdt_addr_r} /boot/dtb/rockchip/rk3588-orangepi-5-max.dtb;
         booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
```

On hitting the `local_kernel` label, U-Boot runs this chain. `setenv bootargs` pins the kernel cmdline to the local rootfs's filesystem label (`armbi_root_local` — matches `disk_provision`'s default label and `pxelinux_render`'s `local_root` default). `nvme scan` ensures the NVMe controller is enumerated. Three `ext4load` calls fetch kernel, initrd, and DTB from partition 4 of the NVMe, addressing them via the stable Armbian symlinks `/boot/Image`, `/boot/uInitrd`, `/boot/dtb/<board-dtb>` — these are maintained by the `linux-image-*` postinst, so `apt upgrade linux-image-*` on the board is the kernel update mechanism (the #78 strategic win). `booti` then transfers control.

### Why bake-in-binary instead of fw_setenv

`persist_uboot_env.yml` (the rock-5b precedent) writes env from Linux into SPI. That works because rock-5b's defconfig has `CONFIG_ENV_IS_IN_SPI_FLASH=y`. OPi5Max's defconfig has `CONFIG_ENV_IS_NOWHERE=y` (see the comment in `playbooks/build_image.yml` board hook for orangepi5-max) — env is volatile. There are three ways around this:

1. **Patch the defconfig to switch env storage to MMC or filesystem.** Significant surface area: choosing an env offset that won't clobber SPL/U-Boot proper, ensuring saveenv doesn't corrupt the image, validating across cold/warm boots. Out of scope for v1 bring-up.
2. **Bake `localcmd` as a compile-time default env entry.** Userpatch appends to `include/configs/rockchip-common.h`'s `CONFIG_EXTRA_ENV_SETTINGS` (or equivalent). Changing requires a rebuild. Fits OPi5Max bring-up — `localcmd` is a stable design choice, not a tuning knob.
3. **Use boot.scr.** Adds a new build artifact and TFTP path. More surface than (2) for the same outcome.

We pick (2). The userpatch is per-board (`build_userpatches[orangepi5-max]`) so other boards are unaffected.

### Role / playbook surface

| Surface | Change |
|---|---|
| `roles/pxelinux_render/templates/pxelinux_cfg.j2` | Add `label local_kernel` with `localboot 0` body. No `kernel`/`initrd`/`fdt`/`append`. |
| `roles/pxelinux_render/tasks/main.yml` | Add `local_kernel` to the built-in modes union. |
| `roles/pxelinux_render/meta/argument_specs.yml` | Document new mode in `boot_mode` description. |
| `roles/board_boot_verify/tasks/main.yml` | Add a `boot_mode == 'local_kernel'` block that asserts `_root_device` is NVMe-prefixed (`^/dev/nvme`) and `_root_fstype` is not NFS. |
| `roles/board_boot_verify/meta/argument_specs.yml` | Add `local_kernel` to choices. |
| `playbooks/build_image.yml` `build_userpatches[orangepi5-max]` | Add a userpatch that injects `localcmd=bootflow scan -b` into the U-Boot binary's default environment via `CONFIG_EXTRA_ENV_SETTINGS` (or per-board `default_environment[]`). |
| `extensions/molecule/pxelinux_render/converge.yml` + `verify.yml` | Render a `local_kernel` fixture; assert label body. |

No new playbook is needed — `converge_boot_mode.yml` already drives any boot-mode value through render → upload → cycle → verify.

### Rendered pxelinux.cfg

With `armbian_netboot_boot_mode: local_kernel` on `orange-pi-5-max-01`:

```
# pxelinux.cfg for orange-pi-5-max-01 (orange-pi-5-max)
# MAC: aa:bb:cc:dd:ee:01
# Active mode: local_kernel
# Generated by Ansible — do not edit manually.

default local_kernel
timeout 50
prompt  0

label nfs
  menu label Armbian NFS root (orange-pi-5-max-01)
  kernel armbian/orange-pi-5-max/vmlinuz
  initrd armbian/orange-pi-5-max/initrd.img
  fdt    armbian/orange-pi-5-max/board.dtb
  append root=/dev/nfs nfsroot=10.10.9.213:/mnt/ssd/netboot/rootfs/orange-pi-5-max-01,nfsvers=3,rw ip=dhcp console=ttyS2,1500000n8 rootwait rw

label sd
  menu label Armbian on SD (orange-pi-5-max-01)
  kernel armbian/orange-pi-5-max/vmlinuz
  initrd armbian/orange-pi-5-max/initrd.img
  fdt    armbian/orange-pi-5-max/board.dtb
  append root=LABEL=armbi_root rootfstype=ext4 rootwait rw console=ttyS2,1500000n8

label local
  menu label Armbian on local disk (orange-pi-5-max-01)
  kernel armbian/orange-pi-5-max/vmlinuz
  initrd armbian/orange-pi-5-max/initrd.img
  fdt    armbian/orange-pi-5-max/board.dtb
  append root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console=ttyS2,1500000n8

label local_kernel
  menu label Boot local kernel from NVMe (orange-pi-5-max-01)
  localboot 0
```

Other modes (`nfs`/`sd`/`local`) remain rendered so an operator can flip back without re-uploading. Selection is by the `default` directive at the top.

### U-Boot userpatch (orangepi5-max only)

Implemented as `pre_config_uboot_target__999_orangepi5max_localcmd` in `build_userpatches_common`'s `config/sources/families/rockchip-rk3588.conf` overlay (alongside `__999_pxe_first`, `__999_rock5b_uboot_v2026_04`, etc.). The hook is BOARD- and BRANCH-gated (`orangepi5-max` + `edge`); other boards are untouched.

What it does:

1. Verifies `include/configs/rockchip-common.h` exists.
2. Locates the `CFG_EXTRA_ENV_SETTINGS` macro header (or the legacy `CONFIG_`-prefixed name from pre-v2024.01) — fails the build loudly if neither is present, so an upstream rebase can't silently produce a binary without `localcmd`.
3. Idempotency-guards on the literal `localcmd=setenv bootargs root=LABEL=armbi_root_local` substring, so re-runs against a cached U-Boot tree don't accumulate duplicates.
4. `printf` builds one continuation line containing `\t"localcmd=<chain>\0" \` with deterministic escape handling; `sed r` inserts it immediately after the macro header. The macro is a backslash-continued `\0`-terminated string concatenation, so one extra entry is well-formed.
5. Post-condition grep verifies the marker text landed in the file (defends against sed silently matching 0 lines).

Hardcoded constants (OPi5Max-only v1; documented brittleness in the hook's comment):

- NVMe partition number `nvme 0:4` — bound to `disk_provision`'s 4-partition layout (root last).
- DTB filename `rockchip/rk3588-orangepi-5-max.dtb` — per-board.
- Root filesystem label `armbi_root_local` — matches `disk_provision` default + `pxelinux_render` `local_root` default.
- Console `ttyS2,1500000n8` — per-board from `vars/boards.yml.console`.

Generalizing for other boards would lift these into `vars/boards.yml` entries (e.g. `local_kernel_root_part`, `local_kernel_console`) and template-substitute at build time. Not in v1 scope.

## Bring-up plan

1. **Phase 1 (this session, no hardware)**: roles + molecule scenarios + spec. Lands as a PR; CI green; image not yet rebuilt.
2. **Phase 2 (bring-up, hardware in the loop)**: image rebuild with the orangepi5-max userpatch; reflash SD on opi5max-01; flip `armbian_netboot_boot_mode: local_kernel`; `converge_boot_mode.yml --limit orange-pi-5-max-01`; UART capture; iterate on `localcmd` body until `bootflow scan` finds NVMe extlinux.conf and boots.
3. **Phase 3 (verify)**: confirm `findmnt /` matches local label, `/proc/cmdline` shows Armbian's NVMe-side bootargs (not rb5009's), and a fresh `apt install linux-image-current-edge` followed by cold cycle results in the new kernel running. The latter is the strategic win.
4. **Phase 4 (document)**: update spec with the concrete `localcmd` body and any U-Boot-side gotchas. Cross-link to #78.

## Verification

| Layer | What | When |
|---|---|---|
| Molecule (pxelinux_render) | `local_kernel` label renders with `localboot 0` body and no `kernel/initrd/fdt` directives | CI, Phase 1 |
| Molecule (pxelinux_render, negative) | `local_kernel` accepted; unknown mode still fails fast | CI, Phase 1 |
| board_boot_verify (Phase 3) | Asserts `_root_device` starts with `/dev/nvme` and `_root_fstype` is not NFS when `boot_mode=local_kernel` | First hardware run |
| UART capture (Phase 2/3) | `bootflow scan` lines visible; "Loading /boot/vmlinuz" via extlinux bootmeth on the NVMe bootdev | First hardware bring-up |
| `/proc/cmdline` (Phase 3) | bootargs match what's in NVMe's `/boot/extlinux/extlinux.conf` (i.e. `BOOT_IMAGE=/boot/vmlinuz` or the appended `root=LABEL=armbi_root_local`), NOT rb5009's pxelinux append line | First hardware run |
| Kernel-update sanity (Phase 3) | `apt install linux-image-edge-rockchip-rk3588=<new-ver>` followed by cold cycle → `uname -r` reports new version. This is the strategic acceptance criterion | First hardware run |

## Bring-up revision (LK1, 2026-05-17): Approach A → Approach B

The first hardware iter (`/tmp/iter-LK1/` artifacts; comment posted to the OPi5Max board-tracker) revealed that Approach A — bake `localcmd=bootflow scan -b` and lean on U-Boot's bootstd `extlinux`/`script` bootmeths to discover the boot files on NVMe — does **not** work against `disk_provision`-generated disk layouts.

Why: `disk_provision` calls `systemd-repart` which, in turn, sets GPT partition attribute bit 59 (`0x0800000000000000` — the "GrowFs"/no-auto attribute) on partitions like `armbi_var` and `armbi_root_local`. U-Boot's `bootflow scan` honors no-auto, so partitions carrying this bit are skipped entirely during auto-discovery. Combined with partition 1 (FAT/ESP) failing on `FAT sector size mismatch (fs=4096, dev=512)` — which exits bootstd's per-partition iteration before it ever reaches the ext4 partitions — `bootflow scan -lae nvme0` reports `0 bootflows, 0 valid` against a healthy NVMe with `/boot/boot.scr` and `/boot/Image` actually present on partition 4.

Verbatim serial signature:

```
=> bootflow scan -lae nvme0
Scanning bootdev 'nvme#0.blk#1.bootdev':
  4  extlinux     fs      nvme         1  nvme#0.blk#1.bootdev.part /boot/extlinux/extlinux.conf
     ** File not found, err=-6: No such device or address
  5  script       fs      nvme         1  nvme#0.blk#1.bootdev.part /boot/boot.scr
     ** File not found, err=-6: No such device or address
...
  8  extlinux     media   nvme         2  nvme#0.blk#1.bootdev.part 
     ** No partition found, err=-22: Invalid argument
 10  extlinux     media   nvme         4  nvme#0.blk#1.bootdev.part 
     ** No partition found, err=-22: Invalid argument
...
(0 bootflows, 0 valid)
```

`ext4load nvme 0:4 ${kernel_addr_r} /boot/Image` works fine on the same setup; the ext4 driver doesn't honor the no-auto attribute. So Approach B — bypass bootstd entirely with an explicit `ext4load + booti` chain — works around the layering mismatch. Verified on LK1: board boots to a login prompt, `findmnt /` reports `/dev/nvme0n1p4`, `uname -r` reports the on-disk kernel, `/proc/cmdline` reflects the U-Boot-side `setenv bootargs` (not rb5009's pxelinux append).

Could we instead set `disk_provision`'s GPT attributes differently (drop bit 59) so bootstd would discover the partitions? Probably yes, but the systemd-repart "GrowFs" attribute exists for a real reason (instructs systemd to grow the filesystem on first boot), and re-purposing it just to please U-Boot's bootstd is a layering hack in the other direction. Approach B is the cleaner separation: bootstd handles the well-behaved cases (PXE, FAT-based bootloaders); for disk_provision'd ext4 layouts we drive the boot path explicitly.

Two consequential follow-ups (tracked on the OPi5Max board-tracker):

1. **`disk_provision` should rewrite `/boot/armbianEnv.txt`'s `rootdev=` to the local-disk label.** Currently the file carries the NFS-source UUID (the rsync-as-is artifact), which means `boot.scr`-driven booting would set the wrong `root=`. Not on the boot path under the production `local_kernel` model (Approach B's explicit `setenv bootargs` overrides anything armbianEnv.txt would have set), but it's an operator footgun for SD-card boot.scr fall-throughs.

2. **Future generalization** to non-OPi5Max boards lifts the hardcoded constants (partition number, DTB filename, root label, console) into `vars/boards.yml` and template-substitutes them in the userpatch hook. Out of scope for v1; LK1 is the proof point that the mechanism is sound.

## Open questions resolved during bring-up

1. **Exact `localcmd` body** — resolved: Approach B chain (see "Boot model" above). Approach A blocked by GPT no-auto attribute + FAT sector-size mismatch on the ESP.
2. **CONFIG_BOOTSTD_FULL=y status in v2025.04 rk3588 build** — confirmed YES. `bootflow`, `bootmeth`, `bootdev` commands all available. (But bootstd isn't usable for our case per the no-auto issue above.)
3. **Patch mechanism for baking localcmd** — resolved: sed-insert one `"localcmd=...\0"` continuation line into the `CFG_EXTRA_ENV_SETTINGS` macro in `include/configs/rockchip-common.h`. See the hook's comment for the full guard chain.

## Acceptance

Phase 1 done when:
- `local_kernel` is a built-in pxelinux mode (renders, validates, verifies).
- Molecule pxelinux_render scenarios cover positive + verify-body cases.
- This spec is committed.
- README / boot-mode-override.md document the new mode and its OPi5Max-only v1 scope.

Phase 2/3 done when:
- An opi5max-01 cold boot with `boot_mode=local_kernel` lands on NVMe-resident `/boot/vmlinuz`, evidenced by UART + `/proc/cmdline`.
- A subsequent `apt install` of a different kernel version → cold cycle → `uname -r` shows the new version.
