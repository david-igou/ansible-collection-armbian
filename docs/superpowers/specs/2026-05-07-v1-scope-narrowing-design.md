---
name: v1 scope narrowing — netboot capability for orangepi5pro only
description: Trim the collection to a single deliverable for v1 — a custom Armbian SD image whose PXE-first U-Boot lets RouterOS DHCP toggle a board between an NFS rootfs and SD fallback. Delete reprovisioning and on-host bootloader flashing, keep only orangepi5pro, and rewrite documentation around the slimmer surface.
---

# v1 scope narrowing design

## Goal

Reduce the collection to one deliverable: an operator-flashed custom
Armbian SD image for `orangepi5pro` whose U-Boot tries PXE first, so that
toggling a RouterOS DHCP option set switches the board between an NFS
rootfs and the local SD rootfs. v1 proves the netboot path works
end-to-end; what runs over NFS, and why, is deferred. Reprovisioning
and on-host bootloader flashing are out of scope for v1 and the code
that implements them is removed from the repo.

## v1 scope statement

In:
- Custom Armbian image build for `orangepi5pro` (existing
  `armbian_build` role, no changes)
- NFS rootfs / TFTP / pxelinux content population on the netboot server
- RouterOS DHCP option set creation and per-board lease toggling
- PoE power control via the upstream RouterOS switch
- Hardware E2E test (`test_hardware_e2e.yml`) — already v1-shaped:
  disk → nfsroot → disk, with serial capture
- Operator-side conveniences: SSH-key user provisioning on freshly
  flashed Armbian SD images, RouterOS user provisioning

Out (deleted from the repo, not deferred-in-place):
- Reprovision workflow (NFS-rooted board flashing the disk)
- On-host bootloader flashing (SPI / eMMC / SD-in-place)
- All boards other than `orangepi5pro`

The "what runs over NFS / why" question is deferred — v1 just demonstrates
that a board can be flipped between SD and NFS via DHCP and asserts the
transitions in `test_hardware_e2e.yml`.

## Roles and playbooks

Kept:
- Roles: `armbian_build`, `bootstrap_armbian`, `bootstrap_routeros_user`,
  `netboot_assets`, `routeros_dhcp` (slimmed), `routeros_poe`
- Playbooks: `build_image.yml`, `bootstrap_armbian.yml`,
  `bootstrap_routeros_user.yml`, `stage_netboot_assets.yml`,
  `setup_routeros_dhcp.yml`, `enable_netboot.yml`, `disable_netboot.yml`,
  `poe_control.yml`, `test_hardware_e2e.yml` (and its
  `playbooks/tasks/diagnostic_bundle.yml` companion)

Deleted:
- Roles: `roles/bootloader/`, `roles/reprovision/`
- Playbooks: `playbooks/flash_bootloader.yml`, `playbooks/reprovision.yml`

## Slimming inside `routeros_dhcp`

- `defaults/main.yml`: drop `routeros_opt_set_reprovision_prefix` and
  `netboot_modes.reprovision`. Only the `nfsroot` mode survives.
- `tasks/setup_options.yml`: drop the `armbian-reprovision` option set
  and the `armbian-reprovision-bootfile` option-67 entry. Keep option
  66 (TFTP), the nfsroot bootfile entry, and the `armbian-nfsroot`
  bundle.
- `tasks/enable_netboot.yml`: drop the `nfsroot`/`reprovision`
  conditional and the `netboot_mode` validation. Unconditionally set
  `dhcp-option=armbian-nfsroot` on the static lease.
- `tasks/write_pxelinux_cfg.yml`: drop the cross-role
  `{{ role_path }}/../bootloader/vars/boards.yml` include and pull the
  board entry from the new collection-level `vars/boards.yml`.

A possible follow-up rename (`armbian-nfsroot` → `armbian-netboot`) is
deferred — it would touch RouterOS state on every existing deployment.

## Board metadata location

The shared board table moves out of the deleted `bootloader` role and
into a single collection-level file: `vars/boards.yml`. Roles that need
it (`netboot_assets/tasks/preflight.yml`,
`routeros_dhcp/tasks/write_pxelinux_cfg.yml`) load it via
`include_vars` or `vars_files` rather than the cross-role file path.

The surviving fields shrink dramatically because everything
bootloader/reprovision-specific goes away. v1 fields per board:

- `armbian_dl_dir`
- `armbian_board_name`
- `armbian_support`
- `dtb`
- `console`

The whole `roles/bootloader/vars/socs/*.yml` family-defaults structure
is deleted — `emmc_strategy`, `sd_uboot_seek_sectors`,
`uboot_spi_image`, `uboot_disk_image` are all
bootloader-flash-specific.

`host_board_overrides` is dropped in v1. Every field it used to
override (`flash_target_device`, `has_spi`, `has_emmc`,
`emmc_target_device`, `armbian_build_enabled`, …) was either
bootloader/reprovision-specific (gone) or unnecessary for v1's
single-board scope. If multi-unit SKU variation reappears post-v1, the
override hook can return.

## Per-role cleanup

`netboot_assets`:
- `preflight.yml` drops the apt-package existence check (no
  `uboot_apt_package` field in v1) and stops fetching Armbian's
  `Packages.gz`. Keeps the `armbian_image_urls[<board>]` HEAD check.
- `armbian_image_urls[orangepi5pro]` points at the locally-published
  URL `armbian_build` produces (`image_server_url/<board>/<file>.img.xz`),
  per the existing pattern.

`routeros_dhcp`:
- See "Slimming inside `routeros_dhcp`" above.

`armbian_build`: no changes — already orangepi5pro-only and aligned.

`inventory/group_vars/all.yml`:
- Drop `armbian_apt_suite` (consumer was preflight's apt-package check)
- Audit for any dangling references to vars owned by the deleted
  `bootloader` role (`bootloader_target`, `bootloader_skip_if_present`,
  `bootloader_reboot`, `flash_target_device` at the group level, …)
- Keep `armbian_default_password`, `netboot_server_ip`,
  `armbian_image_urls`, NFS/TFTP export paths

`inventory/hosts.yml` (sample/documentation inventory):
- Prune non-v1 boards. Document `orangepi5pro` only in v1.

## Documentation rewrite

- `CLAUDE.md`: rewrite around v1 framing.
  - Add a "Status: v1 = orangepi5pro netboot capability only" header
    near the top, replacing the current "Status: netboot trigger is WIP
    pending the `armbian_build` role" block.
  - Remove sections: reprovision workflow, three-bootloader-flash-paths,
    pre-flight validation's apt-package half, `bootloader_target`
    discussion, SoC family strategy structure, and per-host overrides
    that referred to bootloader fields.
  - Trim the "SBC ecosystem reality" section: keep the framing about
    naming/DTB/console variation; drop dimensions that were
    bootloader-role concerns (eMMC strategies, U-Boot env storage,
    bootloader write strategy).
  - "Adding a new board" guidance reduces to: add an entry under
    `vars/boards.yml`, add an `armbian_image_urls` entry, opt the host
    into `armbian_build`. (Multi-board onboarding is post-v1.)
  - Update the playbook ordering list to the v1 sequence (below).
- `docs/architecture.md`: rewrite to reflect v1 (custom image →
  PXE-first U-Boot → RouterOS DHCP option toggles between NFS rootfs
  and SD fallback). Drop reprovision and on-host bootloader-flash
  discussions.
- `docs/board-bootloader.md`: **delete** — describes the deleted role.
- `docs/routeros-setup.md`: keep, light trim if anything references
  the reprovision option set.
- `docs/superpowers/specs/2026-05-05-collection-direction-design.md`:
  leave as historical context. (This v1 spec supersedes its scope
  description.)
- `MEMORY.md`: index entry on role-intent separation stays — still
  load-bearing for v1.

## v1 workflow ordering

```
0. (Once per board model) Build custom Armbian image    → build_image.yml
1. Operator manually flashes SD card with that image    (out of band)
2. (Once)   Bootstrap RouterOS SSH user                 → bootstrap_routeros_user.yml
3. (Once per board) Bootstrap SD-rootfs SSH user        → bootstrap_armbian.yml
4. (Once)   Create RouterOS DHCP option objects         → setup_routeros_dhcp.yml
5.          Populate NFS exports for a board            → stage_netboot_assets.yml
6.          Toggle board into NFS-root mode             → enable_netboot.yml
7.          Toggle board back to SD                     → disable_netboot.yml

Ad-hoc:
   poe_control.yml          power on/off/cycle via RouterOS PoE
   test_hardware_e2e.yml    SD → NFS → SD assertion cycle (with serial capture)
```

(0) and (3) commute with (2), (4). The order above reflects setting up
a fresh deployment top-to-bottom.

## Out of scope for v1 (deferred to later phases)

- Reprovision workflow — NFS-rooted board flashing its disk from `.img.xz`
- On-host bootloader flashing — `bootloader` role for SPI / eMMC / SD-in-place
- Boards other than `orangepi5pro` — each new board needs its own
  `armbian_build` patch entry (`pre_config_uboot_target__<board>_*`)
- Renaming `armbian-nfsroot` to `armbian-netboot` — touches RouterOS
  state on existing deployments
- Defining the actual workload that runs on NFS-rooted boards
  (diagnostic / managed / something else)

## Acceptance criteria

- `roles/bootloader/` and `roles/reprovision/` no longer exist in the
  repo
- `playbooks/flash_bootloader.yml` and `playbooks/reprovision.yml` no
  longer exist
- `roles/routeros_dhcp/defaults/main.yml` does not mention
  `reprovision`; `routeros_dhcp/tasks/setup_options.yml` creates exactly
  the option 66 entry, the `armbian-nfsroot-bootfile` entry, and the
  `armbian-nfsroot` bundle (3 RouterOS objects total)
- `vars/boards.yml` exists at the collection root and contains exactly
  one entry (`orangepi5pro`)
- `inventory/hosts.yml` documents `orangepi5pro` as the only board
- `playbooks/test_hardware_e2e.yml` still passes against
  `orangepi5pro-01` (no behavioral change — its DHCP-toggle assertion
  loop is already v1-shaped)
- `CLAUDE.md` and `docs/architecture.md` describe the v1 model only;
  `docs/board-bootloader.md` is gone

## Amendments (2026-05-12)

The v1 surface evolved after this spec landed. The acceptance criteria
above are still met; the items below replace or extend specific
sections rather than invalidating them. See git history for the
individual PRs.

### Toggle mechanism: DHCP option-sets → TFTP-only

The spec's "Slimming inside `routeros_dhcp`" section assumed the role
would continue to manage RouterOS DHCP option sets — specifically
option 66 (TFTP), the `armbian-nfsroot-bootfile` entry, and the
`armbian-nfsroot` option bundle attached to per-board static leases.
That surface was removed entirely.

The collection now relies solely on per-board `pxelinux.cfg/01-<MAC>`
presence on rb5009's TFTP server to toggle a board between disk boot
and netboot. U-Boot's PXE bootmeth uses the DHCP `siaddr`
(set by your separate RouterOS-config repo's `next-server`) for
`serverip`, and falls through to local SD when the per-board file
isn't registered as an `/ip tftp` row. No DHCP option-sets and no
lease mutations are owned by this collection.

Consequences relative to the original spec:

- `playbooks/setup_routeros_dhcp.yml` was never created. (Original
  spec listed it under "Kept" playbooks; the role pivot made it
  unnecessary.)
- `roles/routeros_dhcp/tasks/setup_options.yml` was never created.
  The acceptance criterion that it create "exactly the option 66
  entry, the `armbian-nfsroot-bootfile` entry, and the
  `armbian-nfsroot` bundle (3 RouterOS objects total)" is therefore
  void. The role's surviving surface is `main.yml`,
  `write_pxelinux_cfg.yml`, and `remove_pxelinux_cfg.yml`.
- The `routeros_dhcp` role was renamed to `routeros_sbc_tftp` in a
  follow-up PR (same day as this amendment), since post-pivot it does
  not touch DHCP at all — it manages per-board pxelinux.cfg files and
  `/ip tftp` rows on rb5009's flash. The mentions of `routeros_dhcp` in
  the original spec body (above) refer to the pre-rename name; all
  current code and docs use `routeros_sbc_tftp`.

### New role: `board_boot_state`

PR #54 extracted the netboot toggle (write/remove rb5009 state →
PoE-cycle → verify rootfs) into a dedicated role with a formal
`meta/argument_specs.yml` contract. The role composes `routeros_sbc_tftp`
and `routeros_poe` internally and is consumed by `enable_netboot.yml`,
`disable_netboot.yml`, and `test_hardware_e2e.yml`.

The v1 spec's "Roles kept" list (`armbian_build`, `bootstrap_armbian`,
`bootstrap_routeros_user`, `netboot_assets`, `routeros_dhcp`,
`routeros_poe`) now includes `board_boot_state` as a seventh role.
See [`docs/board_boot_state-role.md`](../../board_boot_state-role.md)
and [`docs/retry-configuration.md`](../../retry-configuration.md).

### New per-board field: `earlycon`

`vars/boards.yml` per-board fields gained `earlycon` (e.g.
`uart8250,mmio32,0xfeb50000` for RK3588S). Consulted only by
`roles/routeros_sbc_tftp/templates/pxelinux_cfg.j2` when
`pxelinux_verbose: true`, which drives kernel output before the
ttyS* driver loads. Required when the verbose path is enabled; an
assertion in `routeros_sbc_tftp` fails loud if missing.

The v1 fields list in "Board metadata location" is therefore
`armbian_dl_dir`, `armbian_board_name`, `armbian_support`, `dtb`,
`console`, **`earlycon`**.

### Added playbook: `test_manual_psu_cold_boot.yml`

Operator-driven harness for characterizing the retry stack against a
manually-toggled PSU (no PoE switch involvement). Not listed in the
spec's playbook inventory; additive and independent of the v1
contract.

### Asset host migration (2026-05)

The HTTP asset host moved off the retired netbootxyz container to the
homelab's public nginx container on TrueNAS — URL prefix
`https://public.igou.systems/boot-files/`, host path
`/mnt/ssd/public/boot-files`. `roles/netboot_assets/tasks/per_board.yml`
and `preflight.yml` now compose the local-FS path from the
build-publish invariant (`{{ nfs_assets_export }}/images/<armbian_board_name>/<basename>`)
rather than stripping the URL prefix, so URL and FS layouts can diverge.
Inventory now sets `nfs_assets_export` at inventory scope because
`build_image.yml`'s publish play consumes it without loading the
`netboot_assets` role.

### rock-5b expansion (2026-05-14)

Closes `docs/superpowers/specs/2026-05-12-rock5b-expansion-design.md`.
v1 supports two boards: `orange-pi-5-pro` (the original) and `rock-5b`.
The expansion exercised the 4–5 touchpoints a new ARM SBC hits when
joining the collection and surfaced the friction below.

#### v1 board scope: two boards

The original spec's "vars/boards.yml contains exactly one entry
(orangepi5pro)" criterion is voided. Replacement: `vars/boards.yml`
contains entries for `orange-pi-5-pro` and `rock-5b`. The "out of
scope: all boards other than orangepi5pro" line is replaced by "all
boards other than `orange-pi-5-pro` and `rock-5b`". The next board
onboarding goes against the runbook in the `adding-armbian-board`
skill, not this spec.

#### Per-phase friction — Phase 1 (image build)

- **Per-board u-boot branch override** required when the family
  default's u-boot tree lacks driver support. Rock-5b on the
  Rockchip-RK3588 family default (`current` branch → Radxa's
  `next-dev-v2024.10` u-boot fork) has **no RTL8125 PCIe driver
  source files at all**, so PXE is impossible there. The `edge`
  branch triggers armbian/build's existing
  `post_family_config_branch_edge__rock-5b_use_mainline_uboot` hook
  pulling mainline u-boot (currently v2026.04 via our `__999_` override).
  Side-effect: rock-5b's kernel goes to edge (7.0.x) while
  orange-pi-5-pro stays on current (6.18.x). Landing:
  `playbooks/build_image.yml` `build_branches:` dict — the mechanism
  is now in the v1 surface, not just a per-board patch (commit
  9779139).

- **PXE-first userpatch was a no-op for some u-boot forks.** Original
  sed targeted `#define BOOT_TARGETS` (legacy form); Radxa's
  `next-dev-v2024.10` (rk3588 family default for `current`) uses the
  X-macro `BOOT_TARGET_DEVICES(func)` form. Orange-pi-5-pro worked by
  accident — its `u-boot-orangepi5pro/v2025.10` fork also uses legacy
  form. Fixed with a dual-form patch, then refactored into a single
  family-level overlay at
  `userpatches/config/sources/families/rockchip-rk3588.conf` (commits
  22a5971, 9ce4a1e). Scales to N rk3588 boards without per-board
  duplication.

- **`CONFIG_PCI_INIT_R` must be enabled for rk3588 defconfigs with
  `CONFIG_PCI=y`** (commit bd44240). Without it, PCIe is not
  initialized before `bootflow scan` and PCIe-attached NICs (RTL8125)
  don't appear as bootdevs. Mainline u-boot defconfigs vary on this;
  the family overlay now writes it unconditionally when CONFIG_PCI=y.

#### Per-phase friction — Phase 2 (staging)

Largely uneventful. Generic preflight + per-host clone worked first
time. Confirms the model: when a new board's metadata is correct,
Phase 2 is mechanical and free of board-specific surprises.

#### Per-phase friction — Phase 3 (hardware E2E)

- **Three-layer PXE failure model** for rock-5b (documented in
  `docs/uboot-armbian-build-explainer.html` §8): NIC enumeration
  (layer 0), MAC override by `rockchip_setup_macaddr` (layer 1), PXE
  address vars vanishing under `CONFIG_ENV_IS_IN_SPI_FLASH` semantics
  (layer 2). Each layer needs distinct treatment; the new
  `playbooks/persist_uboot_env.yml` (Approach B) clears layers 1+2 at
  runtime, the family build hooks clear layer 0.

- **`CONFIG_ENV_IS_IN_SPI_FLASH=y` semantics** are
  REPLACE-not-merge: a valid-CRC SPI env replaces compile-time
  defaults; it does not merge with them. First successful `fw_setenv`
  freezes whatever subset of vars happened to be in runtime env, and
  any default not explicitly carried forward is dropped. This is the
  failure mode that bites operators experimenting with `fw_setenv`.
  Recovery is codified out-of-tree in the `recovering-uboot-spi-state`
  operator skill (UART path; Linux path via `persist_uboot_env.yml`).

- **Without UART, U-Boot network bring-up is nearly opaque.** The
  original v1 spec's "more reliable HAT means no UART needed" holds
  for PoE-cycle scenarios but breaks during onboarding when network
  init itself is unreliable. Lesson for the `adding-armbian-board`
  skill: temporary UART wiring is essential during onboarding even if
  the production PoE-HAT plan obviates it.

- **L1 link verification before software diagnosis.** Several hours
  were lost debugging u-boot config while the rock-5b's ethernet
  wasn't connected (the PoE HAT was off the board to access UART,
  severing the network path the HAT was providing). Without
  `Link is Up Speed 1Gbps` in the UART log, absence-of-evidence looks
  identical to a driver bug. Verify L1 at the switch before debugging
  anything software.

- **DHCP `boot-file-name` option fights u-boot's bootflow.** rb5009's
  vlan9 had a legacy `boot-file-name="netboot.xyz.kpxe"` set globally
  (residue from a long-removed netbootxyz container). U-Boot's `efi`
  bootmeth (order 3, before `pxe` at order 4) tries to PE-execute it
  before `pxe` runs and the fetch "succeeds" enough that
  `bootflow scan` accepts it as a bootflow. Workaround:
  `bootmeths=pxe extlinux script efi` in SPI env, which
  `persist_uboot_env.yml` writes. Long-term consideration: per-host
  option-67 override or removal of the global option, in the external
  RouterOS-config repo.

- **Ansible 2.20 regression**: `delegate_to` is no longer valid on
  `include_role` (deprecated since 2.14, error since 2.20). Affected
  `roles/board_boot_state/tasks/configure_pxe.yml` and
  `configure_disk.yml`; without the fix every
  `enable_netboot.yml`/`disable_netboot.yml`/`test_hardware_e2e.yml`
  run would fail on Ansible 2.20+. Fixed by wrapping each
  `include_role` in a `block:` with `delegate_to:` (commit f485401).

- **Vestigial reprovision task removed**:
  `roles/netboot_assets/tasks/per_board.yml:162-167` copied each
  `.img.xz` to `nfs_assets_export/images/<board_model>.img.xz` —
  leftover from the deleted reprovision workflow, no current consumer.
  Removed in commit 2089029.

#### Added v1 surface

- `playbooks/persist_uboot_env.yml` — Approach B for rock-5b
  autonomous PXE; idempotent `fw_setenv` of `ethaddr` + PXE address
  vars + `bootmeths` into SPI, cold-cycles on drift. Required for
  any board with `CONFIG_ENV_IS_IN_SPI_FLASH=y`; harmless on others
  (the playbook is targeted at the `rock_5b` group).

- `playbooks/build_image.yml` `build_branches:` dict — per-board
  u-boot branch override.

- `userpatches/config/sources/families/rockchip-rk3588.conf` family
  overlay — `__999_pxe_first` hook (dual-form sed), v2026.04 u-boot
  pin override for rock-5b, generic `CONFIG_PCI_INIT_R=y` enable for
  CONFIG_PCI=y defconfigs.

#### Deferred refactors

| Refactor | Landing | Why deferred |
|---|---|---|
| Approach A (source patch to `arch/arm/mach-rockchip/board.c::rockchip_setup_macaddr` to skip when DT MAC is valid) | `userpatches/u-boot/v<version>/skip-chip-hash-macaddr.patch` | Upstream-friendly alternative to Approach B; not needed for v1 — Approach B works and is operator-driven |
| `armbian_build` role doesn't prune orphan userpatches files | `roles/armbian_build/tasks/main.yml`, new pre-write task | Functionally harmless (the `__999_` overlay wins); cosmetic builder hygiene |
| Stuck-at-u-boot-prompt recovery as a playbook | New `playbooks/recover_uboot_env.yml`, OR extend `persist_uboot_env.yml` with a detect-and-recover pre-task | Currently lives in the out-of-tree `recovering-uboot-spi-state` skill; a playbook would make the runbook ansible-driven end to end |
| `run-iter.sh` wrapping non-e2e plays (`persist_uboot_env.yml`, `enable_netboot.yml`, etc.) | `playbooks/scripts/run-iter.sh` extension or new wrapper | The operator skill `testing-armbian-board-hardware` Phase 2C documents the manual pattern; could be scripted |
| `update-docs` pre-commit pass via `collection_prep` | `make update-docs` target + CI gate | Not run on this branch's CLAUDE.md/docs updates; consider before tagging v1 to keep generated docs aligned with hand-authored ones |
| Deprecation cleanup pass for `ansible_date_time` → `ansible_facts.date_time` across roles/playbooks | Repository-wide grep + edit | Today's `persist_uboot_env.yml` fix handles the one new instance; older code may have other instances |
