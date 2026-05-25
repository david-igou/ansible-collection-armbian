---
name: adding-armbian-board
description: Use when adding a new ARM SBC board to the david_igou.armbian_netboot Ansible collection, or when bringing up an Armbian-supported board the collection doesn't yet track. Applies to any board armbian/build supports.
---

# Adding a New Board to david_igou.armbian_netboot

## Overview

End-to-end runbook through the `stage_netboot_assets.yml` and
`stage_router.yml` staging milestones. The collection is inventory-driven: a new board is picked
up automatically once inventory, `vars/boards.yml`, and
`armbian_netboot_image_urls` agree.

**Core insight:** ARM SBCs are not uniform. Naming, U-Boot trees, NIC
drivers, MAC sourcing, and SPI-env semantics differ per board. Never
copy fields by analogy — verify each against the specific board's
`armbian/build/config/boards/<board>.conf` and (post-build) its
compiled U-Boot defconfig.

## Phase 0 — Pre-flight

Capture before touching code:

- **Armbian board** exists upstream: `gh api 'repos/armbian/build/contents/config/boards/<board>.conf' --jq '.size'`. Read it for `BOARD_NAME` (filename casing) and any `post_family_config_branch_*__<board>_use_mainline_uboot` override.
- **NIC support in family-default U-Boot tree:** read `config/sources/families/<family>.conf` for `BOOTSOURCE`. If the tree's `drivers/net/` lacks the board's NIC driver, plan on `edge`.
- **PoE wiring** (operator knowledge): `armbian_netboot_poe_switch` + `armbian_netboot_poe_port`.
- **MAC**: use real if known; placeholder `00:00:00:00:00:00` otherwise — `build_image.yml` only reads `armbian_netboot_board_model` from inventory, so build-before-DHCP works.
- **UART**: without it, U-Boot pre-SSH failures are only observable via second-order signals (rb5009 `/ip tftp print where real-filename~"<board>"` HITS=0 ⇒ U-Boot never made a TFTP request).

## Phase 1 — Inventory

Add the host(s) under a new per-model subgroup of `boards` in the real (gitignored) inventory; mirror in doc-only `inventory/hosts.yml`. Required hostvars: `armbian_netboot_board_mac`, `armbian_netboot_board_model` (must equal a `vars/boards.yml` key), `armbian_netboot_poe_switch`, `armbian_netboot_poe_port`.

## Phase 2 — `vars/boards.yml`

Add a key under `armbian_netboot_board_configs` with every field below. All load-bearing — verify, don't guess:

| Field | Source of truth |
|---|---|
| `armbian_dl_dir` | `dl.armbian.com` URL segment (informational). |
| `armbian_board_name` | `BOARD_NAME` in armbian/build's `<board>.conf`. Drives the produced `.img.xz` filename's board segment (case-preserving). |
| `armbian_support` | armbian/build's support tier (`standard`/`community`/`wip`). |
| `dtb` | The board's kernel-deb-shipped `/boot/dtb/<vendor>/<file>.dtb`. |
| `console` | Per board's serial-console docs (RK3588: `ttyS2,1500000n8`; Allwinner: `ttyS0,115200`). |
| `earlycon` | UART MMIO base from SoC RM. Required when `armbian_netboot_pxe_verbose=true`. |

## Phase 3 — Image URL placeholder

Add `armbian_netboot_image_urls[<model>]` in your real `group_vars/all.yml` (and the doc-only one). The `<model>` key must match each host's `armbian_netboot_board_model`. The exact filename is filled in after Phase 4.

## Phase 4 — U-Boot branch decision

Default: `current` (no `armbian_netboot_board_branch` entry needed). Switch to `edge` only when the family-default U-Boot tree can't support the board's NIC — set `armbian_netboot_board_branch: edge` in `inventory/group_vars/<model_group>.yml` (and the same path in your real inventory). The Radxa `next-dev-*` fork (rk3588 family default) lacks the RTL8125 driver, so any rk3588 board with that NIC needs `edge`.

Per-board `armbian_netboot_board_userpatches` entries are rare — `build_userpatches_common` in `playbooks/build_image.yml`'s `__999_pxe_first` family hook covers all rk3588 boards (PXE-first BOOT_TARGETS + appends `CONFIG_PCI_INIT_R=y` when missing). Add a per-board list under `armbian_netboot_board_userpatches` in `inventory/group_vars/<model_group>.yml` only after verifying the existing hooks don't cover the case.

## Phase 5 — Build + audit

```bash
ansible-playbook playbooks/build_image.yml
```

Iterates over all unique `armbian_netboot_board_model` values in `groups['boards']`. Cached boards skip the heavy work. **Known flake:** first build of a new board can segfault during `install_distribution_agnostic` (qemu-user-static + Python pycompile) — retry once before deeper diagnosis.

After the build, audit the compiled defconfig:

```bash
ls /var/lib/armbian_build/build/cache/sources/u-boot-worktree/*/*/configs/<board>*defconfig
```

Verify: `CONFIG_CMD_PXE=y`, `CONFIG_NET=y`, `CONFIG_PCI_INIT_R=y` (when `CONFIG_PCI=y`), and the NIC's driver (e.g. `CONFIG_PHY_REALTEK=y` for RTL8211F PHYs; for PCIe NICs confirm the driver source file actually exists under `drivers/net/`).

Update `armbian_netboot_image_urls[<model>]` to the published filename — read it from `/tmp/armbian_publish/<board>/manifest.json`.

## Phase 6 — Bootstrap + stage

Real inventory must define `armbian_netboot_default_password` (typically `1234`) before bootstrap. Then:

```bash
ansible-playbook playbooks/bootstrap_armbian.yml --limit <hostname>
ansible-playbook playbooks/stage_netboot_assets.yml
ansible-playbook playbooks/stage_router.yml
```

## Phase 7 — Approach B (conditional)

Run `playbooks/persist_uboot_env.yml` **iff** the board's compiled U-Boot defconfig sets `CONFIG_ENV_IS_IN_SPI_FLASH=y`:

```bash
grep '^CONFIG_ENV_IS_IN_SPI_FLASH=y' \
  /var/lib/armbian_build/build/cache/sources/u-boot-worktree/*/*/configs/<board>*defconfig
```

Rationale: a CRC-valid SPI env replaces compile-time `default_environment[]`, erasing `pxefile_addr_r`, `kernel_addr_r`, `ramdisk_addr_r`, `fdt_addr_r`, `scriptaddr`, and `bootmeths` on any successful `fw_setenv`. Approach B re-populates them. Rockchip boards additionally need `ethaddr` set in SPI env so `rockchip_setup_macaddr()` short-circuits — otherwise DHCP DISCOVER carries a SHA-of-cpuid MAC that upstream DHCP reservations don't recognize.

See `docs/uboot-armbian-build-explainer.html` §8 for the three-layer failure model.

## Common mistakes

| Mistake | Cost | Avoid by |
|---|---|---|
| Copy a userpatch by analogy from a "similar" board | Silent no-op — patch never matches, board boots SD, looks like a different bug | The family `__999_pxe_first` hook already covers rk3588; skip per-board userpatches unless you've grepped the actual upstream U-Boot source for the construct you're patching |
| Assume family-default U-Boot supports the board's NIC | 30+ min wasted; HITS=0 on rb5009 with no obvious cause | Inspect `drivers/net/` in the tree before building; opt into `edge` if missing |
| Skip the post-build defconfig audit | Layer 0 / driver bugs hide until E2E test | Run Phase 5's grep checks before flashing the SD |
| Mismatch case between `armbian_netboot_board_model` and `armbian_board_name` | `stage_netboot_assets.yml` / `stage_router.yml` or preflight 404s on the image URL | `armbian_netboot_board_model` is the inventory + `vars/boards.yml` key (typically dashed); `armbian_board_name` follows Armbian's `.conf` casing |
| Forget `armbian_netboot_default_password` in real inventory | `bootstrap_armbian.yml` dies on the first secret lookup | Set in `group_vars/all/*.yml` (vault-encrypted for prod) |
| Leave stale `userpatches/config/boards/<board>.conf` from removed per-board hooks | Old hook sources at build time as `500_*`, runs before `__999_*` | `rm -f /var/lib/armbian_build/build/userpatches/config/boards/<removed>.conf` on the builder after refactoring |

## Cross-references

- `docs/uboot-armbian-build-explainer.html` §8 — three-layer failure model + Approach B rationale.
- `docs/superpowers/specs/.rock5b-friction-notes.md` — empirical baseline this skill is built on.
- `CLAUDE.md` "Adding a new board" — short pointer + minimum-touched-files list.
- `docs/boot-mode-override.md`, `docs/retry-configuration.md` — boot-mode convergence + retries (post-staging); role contract via `ansible-doc -t role david_igou.armbian_netboot.boot_mode`.
