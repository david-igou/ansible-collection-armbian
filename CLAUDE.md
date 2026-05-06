# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The `david_igou.armbian_netboot` Ansible collection for managing Armbian-based
ARM SBCs end-to-end. PXE-netboot and reprovisioning are workflows built on the
collection's primitives — they are not the framing.

A RouterOS DHCP change is the sole trigger for switching a board between disk boot
and netboot. The netboot server (running netboot.xyz + NFS) is assumed to already
be running; this collection manages its NFS export contents, RouterOS DHCP
configuration, PoE power state, and (via `armbian_build`) the custom Armbian
images those workflows consume.

## Mental model: roles + workflow playbooks

**Roles are single-purpose, parameter-driven state enforcers. Playbooks compose
them into workflows.** A role asks "given these inputs, is the world in the
desired state, and if not, make it so." It does not decide intent; callers do.
A playbook decides which roles to invoke, against which inventory, with which
parameters, in what order.

| Role | Enforces / produces |
|---|---|
| `armbian_build` *(WIP, [#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16))* | `.img.xz` Armbian image with PXE-first U-Boot baked in, published to netboot server |
| `bootloader` | U-Boot flashed on a target device (SPI / eMMC / SD) — transition path for boards still on stock images |
| `bootstrap_armbian` | SSH-key user with passwordless sudo on a freshly flashed board |
| `bootstrap_routeros_user` | RouterOS user / group / SSH-key state |
| `nfs_content` | rootfs / TFTP / pxelinux content under server exports |
| `reprovision` | Armbian image flashed to a disk on the board |
| `routeros_dhcp` | Shared DHCP option-set objects + per-lease assignment on RouterOS |
| `routeros_poe` | PoE port state (on/off) on RouterOS switch ports |

The `bootloader` role is structured around per-SoC-family strategies
(`roles/bootloader/vars/socs/<family>.yml`); current implementations cover
Rockchip (RK3588/RK3588S/RK3399/RK356x via Armbian's unified U-Boot format) and
Allwinner (sunxi). Adding a new SoC family is a vars file plus, if its eMMC
layout differs, a per-strategy task file under
`roles/bootloader/tasks/flash_emmc_*.yml`.

## ⚠️ Status: netboot trigger is WIP pending the `armbian_build` role

PXE-first is delivered by custom Armbian images built by the `armbian_build`
role, not by stock Armbian. Stock Rockchip `current` U-Boot ships `BOOT_TARGETS`
with PXE at position 6, and the SD-card `boot.scr` wins via `bootflow scan`
before PXE is reached — `enable_netboot.yml` and `reprovision.yml` therefore
boot from disk on those boards out of the box. The other playbooks
(`flash_bootloader.yml`, `populate_nfs_content.yml`, `setup_routeros_dhcp.yml`)
are correct in isolation. Tracked in
[issue #16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16);
empirical evidence in
[issue #2](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/2).

v1 of `armbian_build` produces full `.img.xz` images for one board
(`orangepi5pro`); the U-Boot deb path is a separate follow-up issue. See
[`docs/superpowers/specs/2026-05-05-collection-direction-design.md`](docs/superpowers/specs/2026-05-05-collection-direction-design.md)
for the directional plan.

When making changes, do not "fix" the architecture invariant by re-adding
env-touching code — `CONFIG_ENV_IS_NOWHERE=y` makes that path permanently closed
for these debs. The PXE-first ordering must come from the U-Boot binary's
compile-time `BOOT_TARGETS`, which the `armbian_build` role patches via
`armbian/build`'s `pre_config_uboot_target__<board>_*` hook before U-Boot is
configured.

## Collection structure

```
david_igou/armbian_netboot/   (this repo root)
├── galaxy.yml                # Collection metadata (namespace, version, dependencies)
├── ansible.cfg               # Ansible config for running playbooks directly from this root
├── requirements.yml          # External collection dependencies
├── meta/runtime.yml          # Minimum Ansible version (>=2.15)
├── roles/
│   ├── armbian_build/             # WIP (#16): build custom .img.xz on armbian_builders host
│   ├── bootloader/                # U-Boot flashing (SPI / eMMC / SD), all on the board
│   │   ├── tasks/                 # main.yml, flash_spi.yml, flash_emmc.yml,
│   │   │                          # flash_sd.yml + per-strategy files
│   │   │                          # (flash_emmc_boot_partition.yml,
│   │   │                          # flash_emmc_user_area_seek.yml)
│   │   └── vars/
│   │       ├── boards.yml         # Per-board configs
│   │       └── socs/              # SoC family defaults (rockchip.yml, allwinner.yml, …)
│   ├── bootstrap_armbian/         # Provision passwordless-sudo SSH-key user on a fresh board
│   ├── bootstrap_routeros_user/   # Provision RouterOS user/group/SSH keys
│   ├── nfs_content/               # Populate NFS exports (preflight + per-model + per-host)
│   ├── reprovision/               # Flash Armbian image to disk from NFS root
│   ├── routeros_dhcp/             # RouterOS DHCP option management
│   └── routeros_poe/              # PoE power control via RouterOS switch
├── playbooks/
│   ├── bootstrap_armbian.yml        # (0) Provision SSH-key user on freshly flashed boards
│   ├── bootstrap_routeros_user.yml  # (1) Provision RouterOS user/group/SSH keys
│   ├── populate_nfs_content.yml     # (2) Populate NFS rootfs + TFTP content
│   ├── setup_routeros_dhcp.yml      # (3) Create RouterOS DHCP option objects
│   ├── flash_bootloader.yml         # (4) Flash U-Boot to SPI / eMMC / SD on the board
│   ├── reprovision.yml              # (5) Full Ansible-driven reprovision workflow
│   ├── build_image.yml              # WIP (#16): build custom Armbian .img.xz for opted-in boards
│   ├── enable_netboot.yml           # Ad-hoc: enable PXE (nfsroot or reprovision)
│   ├── disable_netboot.yml          # Ad-hoc: revert to disk boot
│   └── poe_control.yml              # Ad-hoc: PoE power on/off/cycle via switch
├── .inventory/               # Real inventory (gitignored), used at runtime
├── inventory/                # Documentation-only sample inventory (not used at runtime)
│   ├── hosts.yml             # Example groups, host variables, and naming conventions
│   └── group_vars/
│       ├── all.yml           # Global vars: netboot_server_ip, image URLs, apt suite
│       └── routeros.yml      # RouterOS network_cli connection plumbing only
│                             # (no per-host identity — that lives in hosts.yml)
└── docs/
    ├── architecture.md
    ├── board-bootloader.md
    └── routeros-setup.md
```

## Running playbooks

The `ANSIBLE_INVENTORY` environment variable points to the real inventory directory
(`.inventory/`, gitignored). Always verify this env var is set before running playbooks.
Do not pass `-i` explicitly unless the user overrides this convention.

Run playbooks from the collection root (where `ansible.cfg` is):

```bash
# Install required external collections first
ansible-galaxy collection install -r requirements.yml

# (0) Bootstrap a freshly flashed Armbian board: create the inventory's
# `ansible_user` with passwordless sudo + SSH-key auth, drop the first-login
# TUI prompt, and disable sshd password auth. Only needed once per board,
# right after flashing Armbian. Connects as root with armbian_default_password.
ansible-playbook playbooks/bootstrap_armbian.yml --limit rock-5b-01

# (1) Bootstrap the RouterOS SSH user (one-time, against an existing admin user).
ansible-playbook playbooks/bootstrap_routeros_user.yml \
  -e ansible_user=<existing-admin>

# (2) Populate NFS exports with rootfs/kernel/DTB. Runs preflight (validates
# U-Boot apt packages and image URLs are reachable for every board model
# in inventory) before any destructive operation.
ansible-playbook playbooks/populate_nfs_content.yml

# (3) Create the shared RouterOS DHCP option objects (one-time per RouterOS
# device). Re-run after firmware upgrades that may have wiped option state.
ansible-playbook playbooks/setup_routeros_dhcp.yml

# (4) Flash U-Boot on a specific board (board must already run Armbian, including
# boards with no SPI/eMMC: the role flashes the SD card the board is booted
# from, in place). Auto-resolves SPI > eMMC > SD; force with -e bootloader_target=sd.
ansible-playbook playbooks/flash_bootloader.yml --limit rock-5b-01

# (5) Full reprovision workflow (enables PXE, reboots, flashes disk, reboots to disk)
ansible-playbook playbooks/reprovision.yml --limit rock-5b-01

# Ad-hoc: enable netboot (nfsroot or reprovision mode) — boards reboot immediately
ansible-playbook playbooks/enable_netboot.yml \
  --limit rock-5b-01 -e netboot_mode=nfsroot

# Ad-hoc: manually revert a board to disk boot
ansible-playbook playbooks/disable_netboot.yml --limit rock-5b-01

# Ad-hoc: PoE power cycle a board via its upstream RouterOS switch
ansible-playbook playbooks/poe_control.yml --limit rock-5b-01 -e poe_action=cycle

# Ad-hoc: power off all boards
ansible-playbook playbooks/poe_control.yml --limit boards -e poe_action=off

# Ad-hoc hardware E2E test: toggle a board through disk → nfsroot → disk
# and assert each transition (post manually-flashed SD card).
ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01

# Same, preserving the failure state for forensic debugging if a phase fails:
ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01 -e leave_state=true

# Same, with a USB-UART capturing serial console to /tmp/serial-<host>.log
# on the serial host. Defaults to localhost (whatever connection the
# inventory's localhost entry uses) at /dev/ttyUSB0 @ 1500000 baud
# (Rockchip current). Serial host needs `socat` installed and the
# connection user needs passwordless sudo. Override host/device/baud
# independently:
#   -e serial_host=<inventory-host>   if the dongle is on a separate machine
#   -e serial_device=/dev/ttyUSB1     non-default device path
#   -e serial_baud=115200             Allwinner / non-Rockchip baud
# The diagnostic bundle prints the last 200 serial lines at every checkpoint.
ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01 -e capture_serial=true
```

## Inventory: documentation vs. real

The `inventory/` directory in this repo is **documentation-only** — it illustrates
the expected group structure, host variables, and naming conventions but is never
used at runtime. The real (gitignored) inventory lives in `.inventory/` and is
picked up via the `ANSIBLE_INVENTORY` environment variable. When validating changes
against real hosts, use the `.inventory/` content (e.g. `ansible -m ping boards`
resolves from there). Do not modify `.inventory/` for documentation purposes;
update `inventory/hosts.yml` instead to keep the example accurate.

**Agent requirement**: before running any `ansible-playbook`, `ansible`, or
`ansible-lint` command, verify both conditions hold:
1. `echo $ANSIBLE_INVENTORY` prints a path ending in `.inventory/` (or the
   absolute path to this repo's `.inventory` directory).
2. The `.inventory/` directory exists and contains at least a `hosts.yml`.

If either check fails, stop and ask the user — do not fall back to
`inventory/hosts.yml` (that file is sample data with placeholder IPs/MACs).

## Required configuration before first run

Inventory (`inventory/hosts.yml`) — SSH connection details on host entries:

- `netboot_server` host: `ansible_host`, `ansible_user`, `ansible_become: true`
- `routeros` host: `ansible_host`, `ansible_user` (`ansible-netboot` after bootstrap),
  `ansible_port` (often non-default if you've moved RouterOS SSH off 22)

`inventory/group_vars/all.yml` — collection-level variables:

- `netboot_server_ip` — IP used as the default for both TFTP/HTTP (DHCP option 66 +
  `image_server_url`) and NFS (`nfsroot=<ip>:<path>` in pxelinux.cfg).
- `tftp_server_ip` (optional) — overrides `netboot_server_ip` for the TFTP/HTTP role.
  Set in split-host topologies (e.g. netboot.xyz container on a macvlan network at one
  IP, NFS exported from the host at another).
- `nfs_server_ip` (optional) — overrides `netboot_server_ip` for the NFS role.
- `routeros_dhcp_server_name` — `/ip dhcp-server` name on RouterOS (default `dhcp1`).
- `armbian_apt_suite` — Armbian apt suite (default `bookworm`); used by preflight to fetch the package index
- `armbian_default_password` — Armbian NFS root SSH password (default `1234`); encrypt with vault
- `armbian_image_urls` — full `.img.xz` URL per board model, found at `https://dl.armbian.com/<armbian_dl_dir>/`
- `tftp_nfs_export` (overridable) — TFTP server's document root. Default
  `/mnt/ssd/containers/netbootxyz/config/menus` matches netboot.xyz container's
  dnsmasq `--tftp-root`. Override if you run TFTP differently.
- `nfs_assets_export` (overridable) — HTTP server's document root. Default
  `/mnt/ssd/containers/netbootxyz/assets` matches netboot.xyz container's nginx root.

`inventory/group_vars/routeros.yml` only pins the network_cli connection plumbing
(`ansible_connection`, `ansible_network_os`); it intentionally does **not** set
`ansible_user` / `ansible_port` — those are per-host values in `hosts.yml`.

**Three RouterOS groups in `inventory/hosts.yml`**:

- `routeros_routers` — devices that run a DHCP server. All per-board plays
  (`enable_netboot.yml`, `disable_netboot.yml`, `reprovision.yml`) and
  `setup_routeros_dhcp.yml` target this group; the DHCP-mutating commands would fail
  on switches.
- `routeros_switches` — devices that don't run DHCP but should still get the SSH user.
- `routeros_netboot` — subset that `bootstrap_routeros_user.yml` provisions the
  `ansible-netboot` user on (typically the same as `routeros_routers + routeros_switches`).
- `routeros` (optional parent) — convenience group that includes both router and
  switches; not directly targeted by any playbook.

The NFS rootfs export root (`nfs_rootfs_path`) must already exist on the netboot server
and be exported. Within it, the role creates `_templates/<model>/` (per-model rootfs
template) and `<inventory_hostname>/` (per-host rootfs clone) automatically. The control
node needs SSH (with `become: true`) to the netboot server, but does not need an NFS client.

Each board in `inventory/hosts.yml` needs `board_mac` and `board_model` set. The `board_model`
value must exactly match a key in `roles/bootloader/vars/boards.yml`.

For PoE-powered boards, also set `poe_switch` (inventory hostname of the RouterOS switch
providing power) and `poe_port` (interface name on that switch, e.g. `ether3`). These are
required by `playbooks/poe_control.yml`.

## Architecture

**The intended invariant**: RouterOS DHCP options are the *only* control surface for
switching boot mode. U-Boot tries PXE first and falls through to disk when DHCP provides
no `next-server`.

This invariant is delivered by custom Armbian images built via the `armbian_build`
role (tracked in
[#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16)).
Until a board has been onboarded to that role and reprovisioned with the custom
image, the invariant is aspirational on that board — stock Armbian Rockchip
`current` ships PXE at position 6 in `BOOT_TARGETS` and `bootflow scan` lands on
mmc1's `boot.scr` first.

### Three bootloader flash paths (all run on the board over SSH)
The `bootloader` role picks one of three flash targets at runtime, based on each board's
`has_spi`/`has_emmc` flags and the user-overridable `bootloader_target`
(`auto`/`spi`/`emmc`/`sd`). All three run on the board itself — there is no
netboot-server-side SD card prep step.

- **SPI** — `flash_bootloader.yml` SSHes into the board, `apt install`s the Armbian U-Boot
  deb, detects the SPI MTD by `/sys/class/mtd/mtd*/name`, and `dd`s the SPI binary to it.
- **eMMC** — dispatches to a per-SoC-family strategy:
  - Rockchip (`emmc_strategy: boot_partition`): write to `/dev/mmcblkNboot0` at offset 0,
    toggling `force_ro` around the dd.
  - Allwinner (`emmc_strategy: user_area_seek`): write to the user-data area at sector 16.
- **SD card** — `flash_sd.yml` writes U-Boot to the SD card the board is currently booted
  from, in place, at the SoC-family-specific seek (Rockchip=64, Allwinner=16). Hard-fails
  if the rootfs is not on a removable SD card — refuses to overwrite eMMC or NVMe.
  Operator is expected to have flashed the SD card with Armbian manually before this
  point. Used for boards with no SPI/eMMC populated (e.g. Orange Pi Zero 3, Orange Pi 5
  Pro). The card stays inserted permanently; it acts identically to SPI flash from a
  DHCP perspective.

The role does not touch U-Boot env, does not template `/etc/fw_env.config`, and does
not install `u-boot-tools`. Modern Armbian Rockchip `current` debs build with
`CONFIG_ENV_IS_NOWHERE=y`, so `fw_setenv` would be a no-op even with a config file in
place. The PXE-first ordering must come from the U-Boot binary's compile-time
`BOOT_TARGETS` (set in `include/configs/<soc>-common.h`). The `armbian_build` role
(#16) v1 produces full custom **images** with that ordering patched; the
`reprovision` workflow then lays the custom image down on the disk. The
`bootloader` role remains the transition path for boards still running stock
images (and is the place a future deb-only follow-up will plug in via an
`uboot_apt_source: local` switch — separate issue).

`bootloader_target=auto` (default) resolves: SPI if populated/detected, else eMMC if
populated *and detected*, else SD. Boards with no on-board bootloader storage fall
through to SD automatically — no fail-fast. Detection (`tasks/detect_spi.yml`,
`tasks/detect_emmc.yml`) handles SKU-level variation where `has_spi`/`has_emmc` is
declared in `vars/boards.yml` but the chip isn't populated on a given unit.

### Idempotent flashing and integrity verification
Every flash path runs `tasks/verify_flash.yml` after `dd` completes — reads back the
written region, md5-compares it against the source binary, fails the play with both
checksums shown if they don't match. Catches silent write failures (worn SD card, bad
flash chip, I/O error) instead of leaving a half-written bootloader and reporting
success. With `bootloader_skip_if_present=true`, the same comparison runs *before*
writing via `tasks/check_existing_bootloader.yml`; matching device → flash short-circuits
(no writes, no force_ro toggles, no reboot). Default is `false` to keep reprovisioning
runs unconditionally re-flashing, which is the safer behaviour after U-Boot package
upgrades where the version string hasn't changed but build flags have.

The role owns its post-flash reboot via a `bootloader changed` listener handler. Caller
playbooks set `bootloader_reboot: false` if they want to batch reboots externally
(rarely needed; mostly useful for development loops).

### Pre-flight validation
`populate_nfs_content.yml` runs `roles/nfs_content/tasks/preflight.yml` first, which:
1. Fetches Armbian's apt `Packages.gz` once and asserts every board's `uboot_apt_package`
   exists (failing with the available branches if not).
2. HEAD-checks every board's `armbian_image_urls` entry (failing on 4xx/dead mirror).

Both checks run before any image download or NFS write.

## How NFS content is managed

`populate_nfs_content.yml` connects to the netboot server over SSH
(`hosts: netboot_server`, `become: true`) and operates on the export paths
(`nfs_rootfs_path`, `tftp_nfs_export`, `nfs_assets_export`) directly as filesystem paths
— no NFS client mount on the control node is required. This makes the role compatible with rootless execution environments
(`ansible-navigator` + rootless podman).

Inside `nfs_rootfs_path` two layouts coexist:

```
nfs_rootfs_path/
├── _templates/
│   ├── orange-pi-5/        per-model template (extracted from .img.xz)
│   └── orange-pi-zero-3/
├── orange-pi-5-01/         per-host clone of _templates/orange-pi-5
├── orange-pi-5-02/         per-host clone of _templates/orange-pi-5
└── orange-pi-zero-3-01/
```

Per-host clones are made with `cp --reflink=auto`, which is a zero-cost CoW snapshot on
XFS, btrfs, and ZFS (one rootfs's worth of bytes regardless of host count) and a full copy
on ext4. Hostname, machine-id, and SSH host keys are reset per-host so two same-model
boards have independent identity on the wire — see `roles/nfs_content/tasks/per_host.yml`.
The `pxelinux.cfg/01-<mac>` files point each board at its own per-host export.

`enable_netboot.yml` and `reprovision.yml` write per-board `pxelinux.cfg/01-<mac>`
files directly on the netboot server over SSH, via the `routeros_dhcp` role's
`write_pxelinux_cfg.yml` task file (run from a `hosts: netboot_server`,
`become: true` play). The control node never NFS-mounts the export. Combined with
`nfs_content`'s same model, every write to the netboot server happens over SSH —
no NFS client on the control node, rootless-EE-friendly.

## Reprovision workflow

`reprovision.yml` is fully Ansible-driven — no scripts are staged on the board:

1. Writes pxelinux.cfg and sets RouterOS DHCP option (`armbian-reprovision`) — board boots
   the NFS rootfs with `rw` mount.
2. Reboots the board via SSH.
3. Waits for SSH on the NFS-booted board (connects as `root` using `armbian_default_password`).
4. Asserts the board is booted from NFS, then runs `reprovision` role tasks:
   - Verifies `flash_target_device` exists, is a block device, and (unless `primary_storage=sd`)
     is not removable — guards against accidentally flashing the PXE SD card.
   - Downloads `.img.xz` from netboot.xyz HTTP server to `/tmp`.
   - Flashes to the per-board `flash_target_device` (NVMe/eMMC/SD) with `xz | dd`.
5. Clears RouterOS DHCP option from the control node.
6. Reboots the board and waits for it to come up from the freshly flashed disk.
7. Asserts root filesystem is no longer NFS.

## Where things run

| Playbook | Runs on |
|---|---|
| `bootstrap_armbian.yml` | **boards** (connects as root with `armbian_default_password`; idempotent) |
| `bootstrap_routeros_user.yml` | RouterOS (router + switches via `routeros_netboot`) |
| `populate_nfs_content.yml` | **netboot server** (image extraction, NFS/TFTP content) |
| `setup_routeros_dhcp.yml` | RouterOS (shared DHCP option objects) |
| `flash_bootloader.yml` | **boards** (requires Armbian running + internet for apt; for the SD path, board must be booted from the SD card it should flash) |
| `build_image.yml` *(WIP, #16)* | **`armbian_builders`** (Docker-capable build host; publishes resulting `.img.xz` to **netboot server** over SSH) |
| `enable/disable_netboot.yml` | **netboot server** (pxelinux.cfg over SSH) + RouterOS (DHCP) |
| `reprovision.yml` | RouterOS (DHCP) + **boards** (flash via SSH into NFS root) |
| `poe_control.yml` | **boards** (delegated to `routeros_switches` via `poe_switch` hostvar) |
| `test_hardware_e2e.yml` | **boards** (single-board via --limit) + RouterOS (DHCP toggle, delegated) + RouterOS switch (PoE cycle, delegated to `poe_switch`) |

## SBC ecosystem reality: variation is the rule

ARM SBCs are not standardised hardware. Two boards with the same SoC family
will routinely disagree on naming, file paths, optional features, and software
support tier. Designs that treat boards as uniform (or copy fields from a
"similar" board) will silently break on first contact with new hardware.
Always verify each field against the *specific* board, ideally by reading
the actual `.deb`, the live `/sys` and `/dev` trees, and the Armbian build
config — never by analogy.

The dimensions that vary in practice:

- **Naming**: dl.armbian.com directory, apt package segment, install
  directory under `/usr/lib/`, image filename capitalisation, board family
  identifier, DTB filename. The same board often has 4–5 different
  spellings, and dashing inside any segment is per-board (e.g.
  `orangepi5pro` vs. `orangepi5-max`).
- **Optional features (presence, not just configuration)**: SPI NOR flash
  populated, eMMC socket populated, NVMe M.2 slot populated, microSD slot,
  USB-A vs USB-C boot. These are SKU-level differences, not just
  per-board — the same board model can ship with or without an
  optional component.
- **Boot sources & order**: which device is `mmc0` vs. `mmc1` in U-Boot,
  whether `nvme0` is even known, whether SPI loader exists. The U-Boot
  defconfig per board determines this; it is not derivable from the SoC.
- **Storage device names in Linux**: `/dev/mmcblk0` could be SD or eMMC
  depending on probe order and DT layout; some boards expose eMMC as
  `mmcblk1`. NVMe is usually `/dev/nvme0n1` but can be `/dev/nvme1n1` on
  boards with multiple controllers. SPI MTD is *usually* `/dev/mtd0` but
  can shift if other MTD devices probe first.
- **U-Boot environment storage**: per board *and* per branch. Most modern
  Armbian Rockchip `current` debs build with `CONFIG_ENV_IS_NOWHERE=y`
  (RAM-only env, no `/etc/fw_env.config`, `fw_setenv` is a no-op); a small
  set of boards explicitly opts in to persistent env in `armbian/build`
  (`rock-5b` on `edge`, `rock-5b-plus`, `rock-5t`, `odroidm1`, `nanopct6`).
  Probe `grep CONFIG_ENV_IS_ /usr/lib/<install_dir>/u-boot-config-target-1`
  before assuming `fw_setenv` will work.
- **Console UART**: most current Rockchip boards use `ttyS2` at 1.5 Mbaud;
  Allwinner typically uses `ttyS0` at 115200; i.MX uses `ttymxc*`. Per-board.
- **DTB layout in the rootfs**: `/boot/dtb/<dtb>` on most Armbian images,
  `/boot/dtbs/<kernel-version>/<dtb>` on some kernel packages. The path
  shifts with the kernel package, not the board.
- **Software support tier (Armbian)**: `standard` (CI-tested by Armbian),
  `community` (community maintainer, breakage tolerated), `wip`, or
  unsupported. Influences which kernel branches build (`current`, `edge`,
  `legacy`, `vendor` — never assume all four exist).
- **Armbian U-Boot deb naming**: package name is
  `linux-u-boot-<board>-<branch>` but the deb installs under
  `/usr/lib/linux-u-boot-<branch>-<board>` (segments swapped). See the
  comment block in `roles/bootloader/vars/boards.yml`.
- **Bootloader write strategy**: Rockchip writes to the eMMC boot
  partition (`mmcblkNboot0`); Allwinner writes to the user-data area at
  sector 16; older Rockchip BSP layouts wrote `idbloader.img` + `u-boot.itb`
  separately. Encoded as `emmc_strategy` in `vars/socs/<family>.yml`.

## Field resolution: how `_board` is built

Every role and playbook that consumes board data resolves a single fact, `_board`,
from a three-level merge (later wins):

1. **SoC family defaults** — `roles/bootloader/vars/socs/<soc_family>.yml`. Provides
   the binary names (`uboot_spi_image`, `uboot_disk_image`), the SD card seek offset
   (`sd_uboot_seek_sectors`), and the eMMC write strategy (`emmc_strategy`).
2. **Board entry** — `board_configs.<board_model>` in
   `roles/bootloader/vars/boards.yml`. Per-model identity (apt package, DTB,
   console, capability flags, target device, boot order). Selects the SoC family via
   the `soc_family` field.
3. **Per-host overrides** — `host_board_overrides` dict in inventory host_vars.
   Use sparingly, for SKU-level variation (one Rock 5B unit's SPI is populated,
   another's isn't). Any field is overridable.

```yaml
# inventory/host_vars/rock-5b-02.yml
host_board_overrides:
  has_spi: false                       # this Rock 5B unit has unpopulated SPI
  flash_target_device: /dev/nvme1n1    # NVMe at a non-default address
```

When adding a feature that touches per-board state, add the field to
`board_configs.<model>` (or, if it's family-wide, to `vars/socs/<family>.yml`).
Do not add per-board state to `group_vars/`.

## Adding a new board

1. Find or add a SoC family vars file (`roles/bootloader/vars/socs/<family>.yml`).
   For Rockchip and Allwinner boards using Armbian's modern format, the existing
   files cover you. For a new family (e.g. Amlogic, i.MX) create a new vars file
   and, if the eMMC strategy differs from `boot_partition` or `user_area_seek`,
   add a corresponding `roles/bootloader/tasks/flash_emmc_<strategy>.yml`.
2. Add an entry to `roles/bootloader/vars/boards.yml`. Required fields:
   `soc_family`, `armbian_dl_dir`, `armbian_board_name`, `armbian_support`,
   `uboot_apt_package`, `uboot_install_dir`, `dtb`, `console`, `has_spi`,
   `has_emmc`, `primary_storage`, `flash_target_device`. Verify each value
   against the actual board and the Armbian deb (`dpkg-deb -c`) — do not
   copy by analogy. Boot-order is not a per-board field in this collection;
   it is decided by the U-Boot binary's compile-time `BOOT_TARGETS`. Probe
   the deb's `u-boot-config-target-1` for `CONFIG_ENV_IS_NOWHERE`,
   `CONFIG_BOOTSTD_DEFAULTS`, and `CONFIG_BOOTCOMMAND` to confirm
   bootflow-scan-based PXE-first will work as expected.
3. Add hosts to `inventory/hosts.yml` under a per-model subgroup of `boards`,
   each with `board_mac` and `board_model`.
4. Add a URL to `armbian_image_urls` in `inventory/group_vars/all.yml`.
5. Re-run `populate_nfs_content.yml` — preflight will tell you immediately
   if any value is wrong.
6. Once the `armbian_build` role lands (#16), add a
   `pre_config_uboot_target__<board>_pxe_first` entry to its
   `vars/pxe_first_boards.yml` table, set
   `host_board_overrides.armbian_build_enabled: true` on each host of that
   model, and override `armbian_image_urls[<board_model>]` to the local
   `image_server_url/<board>/<file>.img.xz` URL the role publishes.
   `populate_nfs_content.yml` and `reprovision.yml` consume the custom image
   through the existing path. Run `playbooks/build_image.yml` against
   `armbian_builders` to (re)produce the image whenever the patch table or
   pinned `armbian/build` ref changes.

Notes on Armbian naming inconsistency:

- `armbian_dl_dir` and `armbian_board_name` may differ. Orange Pi 5 Max uses
  `orangepi5-max` as its `dl.armbian.com` subdirectory but `orangepi5max` (no dash)
  as the apt package name segment.
- `uboot_apt_package` is `linux-u-boot-<board>-<branch>` while the deb installs
  under `/usr/lib/linux-u-boot-<branch>-<board>` (segments swapped). Verify both
  by extracting the deb (`dpkg-deb -c`) before adding a new board, since dashing
  inside the board segment varies per board.
- Branch availability is per-board. Some community boards have no `current` deb
  published — only `edge`/`legacy`/`vendor`. The `current` Armbian image and the
  `edge` deb usually ship the same mainline U-Boot for those boards. Preflight
  will catch a typo here and report which branches actually exist.

## RouterOS DHCP objects

Three object types are created once by `setup_routeros_dhcp.yml` and reused for all boards:
- Two `dhcp-option` entries for option 66 (TFTP server) and option 67 (boot file) per mode
- Two `dhcp-option` sets (`armbian-nfsroot`, `armbian-reprovision`) that bundle them

Per-board `enable_netboot` sets `dhcp-option=armbian-nfsroot|armbian-reprovision` on the static
lease; `disable_netboot` clears it to `""`. This is the only per-board RouterOS state.

## PoE power control

`poe_control.yml` targets `boards` with `gather_facts: false` (boards may be powered off)
and delegates the RouterOS command to the switch identified by each board's `poe_switch`
host variable. The `delegate_to` pattern works because `group_vars/routeros.yml` sets
`ansible_connection: ansible.netcommon.network_cli` on all RouterOS hosts, so the
delegated task uses the switch's connection settings automatically.

The role supports three actions via `-e poe_action=`:
- `on` — sets `poe-out=auto` (default)
- `off` — sets `poe-out=off`
- `cycle` — off, pause (`poe_cycle_delay` seconds, default 5), then on

Unlike the DHCP role (which loops over boards from a `hosts: routeros_routers` play),
PoE uses delegation because boards may be connected to different switches. Each board
knows its own switch and port, so delegation routes the command correctly without filtering.

## Key files

- `roles/bootloader/vars/socs/*.yml` — SoC family defaults (binary names, eMMC strategy, SD seek)
- `roles/bootloader/vars/boards.yml` — authoritative per-board hardware config
- `roles/nfs_content/tasks/preflight.yml` — apt package and image URL validation
- `roles/nfs_content/tasks/per_host.yml` — per-host rootfs clone + identity reset
- `inventory/group_vars/all.yml` — IPs, credentials, image URLs, apt suite (edit before first run)
- `roles/reprovision/tasks/main.yml` — flash tasks that run on the board during reprovision
- `roles/routeros_dhcp/templates/pxelinux_cfg.j2` — per-host TFTP boot config template
- `roles/routeros_poe/tasks/main.yml` — PoE power control (delegates to switch)
- `galaxy.yml` — collection namespace, version, and external collection dependencies
