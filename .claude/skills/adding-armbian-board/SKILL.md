---
name: adding-armbian-board
description: Use when adding a new ARM SBC board to the david_igou.armbian Ansible collection, or when bringing up an Armbian-supported board the collection doesn't yet track. Applies to any board armbian/build supports.
---

# Adding a New Board to david_igou.armbian

## Overview

End-to-end runbook through the `stage_netboot_assets.yml` and
`stage_router.yml` staging milestones. The collection is inventory-driven: a new board requires
**no collection edits** — only inventory changes. Board metadata
(`armbian_board_config_model`), build profile (`armbian_build_model`),
and optionally `armbian_rootfs_src` live entirely in inventory.

**Core insight:** ARM SBCs are not uniform. Naming, U-Boot trees, NIC
drivers, MAC sourcing, and SPI-env semantics differ per board. Never
copy fields by analogy — verify each against the specific board's
`armbian/build/config/boards/<board>.conf` and (post-build) its
compiled U-Boot defconfig.

## Phase 0 — Pre-flight

Capture before touching code:

- **Armbian board** exists upstream: `gh api 'repos/armbian/build/contents/config/boards/<board>.conf' --jq '.size'`. Read it for `BOARD_NAME` (filename casing) and any `post_family_config_branch_*__<board>_use_mainline_uboot` override.
- **NIC support in family-default U-Boot tree:** read `config/sources/families/<family>.conf` for `BOOTSOURCE`. If the tree's `drivers/net/` lacks the board's NIC driver, plan on `edge`.
- **PoE wiring** (operator knowledge): `armbian_poe_switch` + `armbian_poe_port`.
- **MAC**: use real if known; placeholder `00:00:00:00:00:00` otherwise — `build_image.yml` only reads `armbian_board_model` from inventory, so build-before-DHCP works.
- **UART**: without it, U-Boot pre-SSH failures are only observable via second-order signals (rb5009 `/ip tftp print where real-filename~"<board>"` HITS=0 ⇒ U-Boot never made a TFTP request).

## Phase 1 — Inventory

Add the host(s) under a new per-model subgroup of `boards` in the real (gitignored) inventory; mirror in doc-only `inventory/hosts.yml`. Required hostvars: `armbian_board_mac`, `armbian_board_model` (must match the key used in `armbian_board_config_model` in the model group_vars), `armbian_boot_mode`; and for PoE-powered boards only: `armbian_poe_switch`, `armbian_poe_port`.

## Phase 2 — Board metadata in inventory group_vars

Create `inventory/group_vars/<model_group>.yml` (and the real inventory equivalent). Add `armbian_board_config_model` with every field below. All load-bearing — verify, don't guess:

| Field | Source of truth |
|---|---|
| `armbian_dl_dir` | `dl.armbian.com` URL segment (informational). |
| `armbian_board_name` | `BOARD_NAME` in armbian/build's `<board>.conf`. Drives the produced `.img.xz` filename's board segment (case-preserving). |
| `armbian_support` | armbian/build's support tier (`standard`/`community`/`wip`). |
| `dtb` | The board's kernel-deb-shipped `/boot/dtb/<vendor>/<file>.dtb`. |
| `console` | Per board's serial-console docs (RK3588: `ttyS2,1500000n8`; Allwinner: `ttyS0,115200`). |
| `earlycon` | UART MMIO base from SoC RM. Required when `armbian_pxe_verbose=true`. |

Also add `armbian_build_model` with at minimum `board: <armbian_board_name>`.
If the board has SoC-family-level fields already covered by
`armbian_board_config_family` in `group_vars/<family>.yml`, inherit from
there and only set the model-specific overrides in `armbian_board_config_model`.

## Phase 3 — Image URL placeholder (optional)

If you want to pin a specific `.img.xz` for hosts in this model group,
add `armbian_rootfs_src` in `group_vars/<model_group>.yml`. The value is
an `https://`, `http://`, or absolute path reachable from both the
netboot_server and the boards. When omitted, `_resolve_rootfs_src.yml`
derives the URL from the published manifest on the netboot server after
`build_and_publish_from_inventory.yml` runs. The exact filename is filled
in after Phase 4.

## Phase 4 — U-Boot branch decision

Default: `current` (no branch entry needed). Switch to `edge` only when the family-default U-Boot tree can't support the board's NIC — set `armbian_build_model.branch: edge` in `inventory/group_vars/<model_group>.yml` (and the same path in your real inventory). The Radxa `next-dev-*` fork (rk3588 family default) lacks the RTL8125 driver, so any rk3588 board with that NIC needs `edge`.

Per-board `armbian_build_model.userpatches` entries are rare — the family-level `armbian_build_family.userpatches` in `group_vars/<family>.yml`'s `__999_pxe_first` hook covers all rk3588 boards (PXE-first BOOT_TARGETS + appends `CONFIG_PCI_INIT_R=y` when missing). Add a per-board list under `armbian_build_model.userpatches` in `inventory/group_vars/<model_group>.yml` only after verifying the existing hooks don't cover the case.

For board-specific armbian/build hook FUNCTIONS (as opposed to source patches against the kernel or U-Boot tree), use `dest: config/boards/<board>.conf`. armbian/build sources that overlay file additively on top of upstream's `config/boards/<board>.conf` only when building that board, so the hook fires per-board structurally — you do not need an internal `[[ "${BOARD}" != "..." ]] && return 0` filter (keep one as defensive belt-and-suspenders if you wish). Source-tree patches still use the `userpatches/u-boot/<version>/<board>/<NNNN-name>.patch` shape — see the orange-pi-5-max RTL8125 patch in `inventory/group_vars/orange_pi_5_max.yml` for an example.

## Phase 5 — Build + audit

```bash
ansible-playbook playbooks/build_and_publish_from_inventory.yml
```

Iterates over every board host in `groups['boards']`, resolving each
host's `armbian_build` profile (via `_resolve_build_profile.yml`) and
invoking `image_build` once per host. Cached boards skip the heavy work.
**Known flake:** first build of a new board can segfault during
`install_distribution_agnostic` (qemu-user-static + Python pycompile) —
retry once before deeper diagnosis.

After the build, audit the compiled defconfig:

```bash
ls /var/lib/armbian_build/build/cache/sources/u-boot-worktree/*/*/configs/<board>*defconfig
```

Verify: `CONFIG_CMD_PXE=y`, `CONFIG_NET=y`, `CONFIG_PCI_INIT_R=y` (when `CONFIG_PCI=y`), and the NIC's driver (e.g. `CONFIG_PHY_REALTEK=y` for RTL8211F PHYs; for PCIe NICs confirm the driver source file actually exists under `drivers/net/`).

If you want to pin this model's image URL explicitly, update
`armbian_rootfs_src` in `group_vars/<model_group>.yml` to the published
URL — read the exact filename from `armbian_nfs_assets_export/images/<model>/manifest.json`
on the netboot server. When omitted, `_resolve_rootfs_src.yml` reads the
manifest automatically on the next `stage_netboot_assets.yml` run.

## Phase 6 — Bootstrap + stage

Real inventory must define `armbian_default_password` (typically `1234`) before bootstrap. Then:

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
| Copy a userpatch by analogy from a "similar" board | Silent no-op — patch never matches, board boots SD, looks like a different bug | The family-level `armbian_build_family.userpatches __999_pxe_first` hook already covers rk3588; skip per-board `armbian_build_model.userpatches` unless you've grepped the actual upstream U-Boot source for the construct you're patching |
| Assume family-default U-Boot supports the board's NIC | 30+ min wasted; HITS=0 on rb5009 with no obvious cause | Inspect `drivers/net/` in the tree before building; opt into `edge` if missing |
| Skip the post-build defconfig audit | Layer 0 / driver bugs hide until E2E test | Run Phase 5's grep checks before flashing the SD |
| Mismatch case between `armbian_board_model` and `armbian_board_name` | `stage_netboot_assets.yml` / `stage_router.yml` or preflight 404s on the image URL | `armbian_board_model` is the inventory group key (typically dashed); per-model hardware facts live in `inventory/group_vars/<model_group>.yml` as `armbian_board_config_model`; `armbian_board_name` follows Armbian's `.conf` casing |
| Forget `armbian_default_password` in real inventory | `bootstrap_armbian.yml` dies on the first secret lookup | Set in `group_vars/all/*.yml` (vault-encrypted for prod) |
| Leave stale `userpatches/config/boards/<board>.conf` from removed per-board hooks | Old hook sources at build time as `500_*`, runs before `__999_*` | `rm -f /var/lib/armbian_build/build/userpatches/config/boards/<removed>.conf` on the builder after refactoring |

## Cross-references

- `docs/uboot-armbian-build-explainer.html` §8 — three-layer failure model + Approach B rationale.
- `docs/superpowers/specs/.rock5b-friction-notes.md` — empirical baseline this skill is built on.
- `CLAUDE.md` "Adding a new board" — short pointer + minimum-touched-files list (collection edits are not required; only inventory edits needed).
- boot-mode convergence + retry knobs (post-staging): the retry primitives live in `playbooks/tasks/cold_boot_with_retry.yml` and friends (no role-level wrapper any more); the knob descriptions live in `roles/board_boot_wait/meta/argument_specs.yml`.
