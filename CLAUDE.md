# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The `david_igou.armbian_netboot` Ansible collection for PXE-netbooting and reprovisioning
Armbian-based ARM SBCs. The bootloader role is structured around per-SoC-family strategies
(`roles/bootloader/vars/socs/<family>.yml`); current implementations cover Rockchip
(RK3588/RK3588S/RK3399/RK356x via Armbian's unified U-Boot format) and Allwinner (sunxi).
Adding a new SoC family is a vars file plus, if its eMMC layout differs, a per-strategy
task file under `roles/bootloader/tasks/flash_emmc_*.yml`.

A RouterOS DHCP change is the sole trigger for switching a board between disk boot and
netboot. The netboot server (running netboot.xyz + NFS) is assumed to already be running;
this collection only manages its NFS export contents and RouterOS DHCP configuration.

## Collection structure

```
david_igou/armbian_netboot/   (this repo root)
├── galaxy.yml                # Collection metadata (namespace, version, dependencies)
├── ansible.cfg               # Ansible config for running playbooks directly from this root
├── requirements.yml          # External collection dependencies
├── meta/runtime.yml          # Minimum Ansible version (>=2.15)
├── roles/
│   ├── bootloader/                # U-Boot flashing (SPI / eMMC / SD), all on the board
│   │   ├── tasks/                 # main.yml, flash_spi.yml, flash_emmc.yml,
│   │   │                          # flash_sd.yml + per-strategy files
│   │   │                          # (flash_emmc_boot_partition.yml,
│   │   │                          # flash_emmc_user_area_seek.yml)
│   │   └── vars/
│   │       ├── boards.yml         # Per-board configs
│   │       └── socs/              # SoC family defaults (rockchip.yml, allwinner.yml, …)
│   ├── bootstrap_routeros_user/   # Provision RouterOS user/group/SSH keys
│   ├── nfs_content/               # Populate NFS exports (preflight + per-model + per-host)
│   ├── reprovision/               # Flash Armbian image to disk from NFS root
│   └── routeros_dhcp/             # RouterOS DHCP option management
├── playbooks/
│   ├── setup_netboot.yml         # Populate NFS exports + create RouterOS DHCP objects
│   ├── flash_bootloader.yml      # Flash U-Boot to SPI / eMMC / SD on the board
│   ├── enable_netboot.yml        # Enable PXE boot (nfsroot or reprovision mode)
│   ├── disable_netboot.yml       # Revert boards to disk boot
│   └── reprovision.yml           # Full Ansible-driven reprovision workflow
├── inventory/
│   ├── hosts.yml             # Sample inventory (multiple hosts per model + Allwinner)
│   └── group_vars/
│       ├── all.yml           # Global vars: IPs, credentials, image URLs, apt suite
│       └── routeros.yml      # RouterOS network_cli (SSH) connection vars
└── docs/
    ├── architecture.md
    ├── board-bootloader.md
    └── routeros-setup.md
```

## Running playbooks

Run playbooks from the collection root (where `ansible.cfg` is):

```bash
# Install required external collections first
ansible-galaxy collection install -r requirements.yml

# Populate NFS exports with rootfs/kernel/DTB and configure RouterOS DHCP objects.
# Runs preflight (validates U-Boot apt packages and image URLs are reachable for
# every board model in inventory) before any destructive operation.
ansible-playbook playbooks/setup_netboot.yml

# Flash U-Boot on a specific board (board must already run Armbian, including
# boards with no SPI/eMMC: the role flashes the SD card the board is booted
# from, in place). Auto-resolves SPI > eMMC > SD; force with -e bootloader_target=sd.
ansible-playbook playbooks/flash_bootloader.yml --limit rock-5b-01

# Enable netboot (nfsroot or reprovision mode) — boards reboot immediately
ansible-playbook playbooks/enable_netboot.yml \
  --limit rock-5b-01 -e netboot_mode=nfsroot

# Full reprovision workflow (enables PXE, reboots, flashes disk, reboots to disk)
ansible-playbook playbooks/reprovision.yml --limit rock-5b-01

# Manually revert a board to disk boot
ansible-playbook playbooks/disable_netboot.yml --limit rock-5b-01
```

## Required configuration before first run

Set all values in `inventory/group_vars/all.yml`:

- `netboot_server_ip` — IP of the host running netboot.xyz + NFS
- `routeros_host` — RouterOS device IP
- `routeros_ssh_user` — username provisioned by `bootstrap_routeros_user.yml` (default `ansible-netboot`)
- `routeros_ssh_port` — SSH port on the RouterOS device (default 22)
- `armbian_apt_suite` — Armbian apt suite (default `bookworm`); used by preflight to fetch the package index
- `armbian_default_password` — Armbian NFS root SSH password (default `1234`); encrypt with vault
- `armbian_image_urls` — full `.img.xz` URL per board model, found at `https://dl.armbian.com/<armbian_dl_dir>/`

The NFS rootfs export root (`nfs_rootfs_path`) must already exist on the netboot server
and be exported. Within it, the role creates `_templates/<model>/` (per-model rootfs
template) and `<inventory_hostname>/` (per-host rootfs clone) automatically. The control
node needs SSH (with `become: true`) to the netboot server, but does not need an NFS client.

Each board in `inventory/hosts.yml` needs `board_mac` and `board_model` set. The `board_model`
value must exactly match a key in `roles/bootloader/vars/boards.yml`.

## Architecture

**The key invariant**: RouterOS DHCP options are the *only* control surface for switching
boot mode. U-Boot always tries PXE first and falls through to disk when DHCP provides no
`next-server`.

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
  from, in place, at the SoC-family-specific seek (Rockchip=64, Allwinner=16). Sets
  PXE-first `boot_targets` via `fw_setenv` on the board's own `/etc/fw_env.config`.
  Hard-fails if the rootfs is not on a removable SD card — refuses to overwrite eMMC or
  NVMe. Operator is expected to have flashed the SD card with Armbian manually before
  this point. Used for boards with no SPI/eMMC populated (e.g. Orange Pi Zero 3, Orange
  Pi 5 Pro). The card stays inserted permanently; it acts identically to SPI flash from
  a DHCP perspective.

`bootloader_target=auto` (default) resolves: SPI if populated/detected, else eMMC if
populated, else SD. Boards with no on-board bootloader storage fall through to SD
automatically — no fail-fast.

### Pre-flight validation
`setup_netboot.yml` runs `roles/nfs_content/tasks/preflight.yml` first, which:
1. Fetches Armbian's apt `Packages.gz` once and asserts every board's `uboot_apt_package`
   exists (failing with the available branches if not).
2. HEAD-checks every board's `armbian_image_urls` entry (failing on 4xx/dead mirror).

Both checks run before any image download or NFS write.

## How NFS content is managed

`setup_netboot.yml` connects to the netboot server over SSH (`hosts: netboot_server`,
`become: true`) and operates on the export paths (`nfs_rootfs_path`, `tftp_nfs_export`,
`nfs_assets_export`) directly as filesystem paths — no NFS client mount on the control node
is required. This makes the role compatible with rootless execution environments
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

`enable_netboot.yml` is the remaining exception to the SSH-and-operate-locally rule: it
still NFS-mounts `tftp_nfs_export` on the control node (`nfs_local_mount` / `tftp_base`) to
write per-board `pxelinux.cfg`. That path will need the same SSH-and-operate-locally
treatment to be fully rootless-EE-friendly.

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
| `setup_netboot.yml` | **netboot server** (image extraction, NFS/TFTP content) + RouterOS (DHCP objects) |
| `flash_bootloader.yml` | **boards** (requires Armbian running + internet for apt; for the SD path, board must be booted from the SD card it should flash) |
| `enable/disable_netboot.yml` | Ansible control node (pxelinux.cfg via NFS mount) + RouterOS (DHCP) |
| `reprovision.yml` | RouterOS (DHCP) + **boards** (flash via SSH into NFS root) |

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
- **U-Boot environment offset/size**: per board, not per SoC. Always read
  the board's own `/etc/fw_env.config` rather than using a hardcoded
  constant.
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
   `has_emmc`, `primary_storage`, `flash_target_device`, `boot_targets_pxe`.
   Verify each value against the actual board and the Armbian deb
   (`dpkg-deb -c`) — do not copy by analogy.
3. Add hosts to `inventory/hosts.yml` under a per-model subgroup of `boards`,
   each with `board_mac` and `board_model`.
4. Add a URL to `armbian_image_urls` in `inventory/group_vars/all.yml`.
5. Re-run `setup_netboot.yml` — preflight will tell you immediately if any
   value is wrong.

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

Three object types are created once by `setup_netboot.yml` and reused for all boards:
- Two `dhcp-option` entries for option 66 (TFTP server) and option 67 (boot file) per mode
- Two `dhcp-option` sets (`armbian-nfsroot`, `armbian-reprovision`) that bundle them

Per-board `enable_netboot` sets `dhcp-option=armbian-nfsroot|armbian-reprovision` on the static
lease; `disable_netboot` clears it to `""`. This is the only per-board RouterOS state.

## Key files

- `roles/bootloader/vars/socs/*.yml` — SoC family defaults (binary names, eMMC strategy, SD seek)
- `roles/bootloader/vars/boards.yml` — authoritative per-board hardware config
- `roles/nfs_content/tasks/preflight.yml` — apt package and image URL validation
- `roles/nfs_content/tasks/per_host.yml` — per-host rootfs clone + identity reset
- `inventory/group_vars/all.yml` — IPs, credentials, image URLs, apt suite (edit before first run)
- `roles/reprovision/tasks/main.yml` — flash tasks that run on the board during reprovision
- `roles/routeros_dhcp/templates/pxelinux_cfg.j2` — per-host TFTP boot config template
- `galaxy.yml` — collection namespace, version, and external collection dependencies
