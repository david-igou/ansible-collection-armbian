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
