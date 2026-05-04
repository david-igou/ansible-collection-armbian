# Architecture

## Overview

```
┌─────────────────────────────────────────────────────────┐
│                    RouterOS Switch/Router                │
│  DHCP server — static leases per board MAC              │
│  Normal state:  no PXE options on lease                 │
│  Netboot state: DHCP option set assigned to lease       │
│                 option 66 = netboot server IP (TFTP)    │
│                 option 67 = pxelinux.cfg path           │
└──────────────┬──────────────────────────┬───────────────┘
               │                          │
    ┌──────────▼──────────┐    ┌──────────▼──────────────┐
    │   Netboot Server    │    │       ARM SBC           │
    │  (already running)  │    │                          │
    │                     │    │  U-Boot (SPI/eMMC/SD)   │
    │  ┌───────────────┐  │    │                          │
    │  │ netboot.xyz   │  │    │  1. DHCP request        │
    │  │ (Docker)      │◄─┼────┤  2. If next-server set:  │
    │  │               │  │    │     TFTP pxelinux.cfg   │
    │  │ TFTP :69      │  │    │     TFTP kernel/initrd/ │
    │  │ HTTP :8080    │  │    │     DTB → boot NFS root │
    │  └───────────────┘  │    │  3. If no next-server:   │
    │                     │    │     boot local disk     │
    │  ┌───────────────┐  │    └──────────────────────────┘
    │  │ NFS Server    │  │
    │  │ /exports/     │  │    ┌──────────────────────────┐
    │  │  rootfs/      │◄─┼────┤  Ansible Control Node    │
    │  │   _templates/ │  │    │                          │
    │  │   <hostname>/ │  │    │  SSHes to netboot server │
    │  └───────────────┘  │    │  to populate exports;    │
    └─────────────────────┘    │  SSHes into NFS-booted   │
                               │  boards to drive flash   │
                               └──────────────────────────┘
```

---

## Boot Modes

### Normal (disk boot)

RouterOS has no PXE DHCP options assigned to the board's static lease.
U-Boot starts from SPI / eMMC / SD card, DHCP returns no next-server, PXE
attempt fails, and U-Boot falls through to NVMe / eMMC / SD as configured
by `boot_targets_pxe` for that board.

### NFS Root (diskless)

The board boots a full Armbian rootfs served over NFS (read-only mount).
Useful for testing, maintenance, or running the board completely off
network storage.

1. `enable_netboot.yml -e netboot_mode=nfsroot` runs
2. RouterOS lease gets `dhcp-option=armbian-nfsroot`
3. Board reboots → U-Boot DHCP → gets next-server + boot file path
4. U-Boot fetches `pxelinux.cfg/01-<mac>` → downloads kernel, initrd, DTB
5. Board boots into Armbian on NFS at
   `nfs_rootfs_path/<inventory_hostname>` (ro). Each host has its own
   per-host rootfs export — see "Per-host rootfs" below.

### Reprovision

Same PXE flow as NFS root, but the rootfs is mounted read-write to give
systemd full write access. Ansible SSHes into the board after it comes up
and drives the flash directly — no scripts are staged on the board.

1. `reprovision.yml` runs
2. RouterOS lease gets `dhcp-option=armbian-reprovision`
3. Board reboots → PXE boots into NFS rootfs (rw mount)
4. Ansible waits for SSH (`root` / `armbian_default_password`)
5. Ansible downloads `.img.xz` from netboot.xyz HTTP server to `/tmp`
6. Ansible flashes the image to `flash_target_device` (NVMe/eMMC/SD)
   with `xz | dd`. The reprovision role refuses to flash a removable
   device (unless `primary_storage=sd`) so the PXE SD card cannot be
   accidentally clobbered.
7. Ansible clears `dhcp-option` on RouterOS from the control node
8. Ansible reboots the board → comes up from freshly flashed disk
9. Ansible asserts root filesystem is no longer NFS

---

## Bootloader: Three Paths

The board's boot behaviour (disk vs. PXE) is controlled entirely by RouterOS
DHCP options regardless of which bootloader path is used. The role picks one
based on each board's `has_spi`/`has_emmc` capability flags and the
`bootloader_target` setting (default `auto`).

### Path 1 — SPI flash

```
SPI flash
└── U-Boot (Armbian linux-u-boot-<board>-<branch>)
      ├── DHCP → next-server set   → PXE boot (nfsroot or reprovision)
      └── DHCP → no next-server    → local disk (NVMe / eMMC / SD)
```

`flash_bootloader.yml` SSHes into the board, `apt install`s the U-Boot
deb, detects the SPI MTD partition by name (`/sys/class/mtd/mtd*/name`),
and `dd`s the SPI binary to it. No physical intervention is needed
afterwards — DHCP is the sole control surface.

### Path 2 — eMMC

The strategy varies by SoC family (`vars/socs/<family>.yml`):

- **Rockchip** (`emmc_strategy: boot_partition`) — write the U-Boot binary
  to `/dev/mmcblkNboot0` at offset 0, toggling `force_ro` around the dd.
- **Allwinner** (`emmc_strategy: user_area_seek`) — write to the eMMC user
  data area at sector 16 (no boot partition involved).

```
eMMC
├── boot0 partition (Rockchip)            or  ├── user area sector 16 (Allwinner)
│   └── U-Boot binary                          │   └── U-Boot binary
└── user partition: rootfs / disk image        └── user partition: rootfs / disk image
```

### Path 3 — SD card (boards without SPI or eMMC populated)

```
SD card (the one the board is currently booted from)
└── U-Boot
      ├── boot_targets = pxe-first (per-board boot_targets_pxe)
      ├── DHCP → next-server set   → PXE boot (nfsroot or reprovision)
      └── DHCP → no next-server    → local disk
```

The starting point is an SD card the operator has manually flashed with
the Armbian image (etcher / `dd` / Armbian installer). The board boots
from it. `flash_bootloader.yml` then SSHes into the board and:

- `apt install`s the Armbian U-Boot deb (provides `u-boot-rockchip.bin`
  / `u-boot-sunxi-with-spl.bin` under `/usr/lib/<install_dir>/`).
- Resolves the rootfs disk via `findmnt -n -o SOURCE / | lsblk -no PKNAME`
  and asserts it's a removable SD card (`/sys/block/<dev>/removable=1`
  or `device/type=SD`). Refuses to write to eMMC or NVMe under this code
  path.
- `dd`s the U-Boot binary to that disk at the SoC family's
  `sd_uboot_seek_sectors` (Rockchip=64, Allwinner=16) with `conv=notrunc`.
  These offsets sit before the first Armbian partition (~sector 8192),
  so the rootfs partition is untouched.
- Calls `fw_setenv boot_targets "<boot_targets_pxe>"` against the board's
  own `/etc/fw_env.config` to put PXE first.

The card stays inserted permanently; it acts identically to SPI flash
from a DHCP perspective.

For boards with `has_spi: false` and `has_emmc: false`, `bootloader_target=auto`
falls through to the SD path automatically. To force it on a board that
has SPI/eMMC populated but should still flash SD, pass
`-e bootloader_target=sd`.

---

## Per-host rootfs

Multiple boards of the same model are supported. The `nfs_content` role
runs in two passes:

1. **Per board model** — extract one Armbian image into a template
   directory `nfs_rootfs_path/_templates/<board_model>/`.
2. **Per inventory host** — `cp --reflink=auto` the template into
   `nfs_rootfs_path/<inventory_hostname>/`, then reset hostname,
   machine-id, and SSH host keys so the host has independent identity
   on the wire when it boots.

```
nfs_rootfs_path/
├── _templates/
│   ├── orange-pi-5/        (extracted from .img.xz; read-only after setup)
│   └── orange-pi-zero-3/
├── orange-pi-5-01/         (reflink clone of _templates/orange-pi-5)
├── orange-pi-5-02/         (reflink clone)
└── orange-pi-zero-3-01/
```

`cp --reflink=auto` is a zero-cost CoW snapshot on XFS, btrfs, and ZFS
(one rootfs's worth of bytes regardless of host count) and a full copy
on ext4. Each board's `pxelinux.cfg/01-<mac>` points at its own
`<inventory_hostname>` export, so two same-model boards never collide
on hostname, machine-id, SSH host keys, or systemd state.

---

## Pre-flight

`populate_nfs_content.yml` runs `roles/nfs_content/tasks/preflight.yml` first,
before any image is downloaded or any rootfs is touched. It validates:

- Each board's `uboot_apt_package` exists in the Armbian apt repo (fetches
  `Packages.gz` once and asserts presence; failure lists the available
  branches for that board family).
- Each board's `armbian_image_urls` entry returns 200/302 to a HEAD
  request (catches dead mirrors and typos).

Failures are cheap to fix; the same misconfiguration caught at flash time
on a real board is much more painful.

---

## How NFS Content is Managed

This collection does not configure the netboot server — it only populates
the NFS exports that netboot.xyz and the boards consume. All writes happen
from the netboot server itself, which the control node reaches over SSH:

```
Control node ──SSH──> Netboot server (runs all extract/copy/clone work)
                          │
                          ├── writes nfs_rootfs_path/_templates/<model>/
                          ├── writes nfs_rootfs_path/<inventory_hostname>/
                          ├── writes tftp_nfs_export/armbian/<model>/{vmlinuz,initrd,dtb}
                          └── writes nfs_assets_export/images/<model>.img.xz
```

The control node needs no NFS client mount, no root, and works under a
rootless execution environment (ansible-navigator + rootless podman).
`enable_netboot.yml` and `reprovision.yml` follow the same pattern:
per-board `pxelinux.cfg/01-<mac>` files are written on the netboot
server over SSH (via the `routeros_dhcp` role's
`write_pxelinux_cfg.yml` task file) before the RouterOS DHCP option
flip — no NFS mount on the control node.

---

## Trigger Reference

| # | Goal | Command |
|---|---|---|
| 1 | Provision the RouterOS SSH user | `ansible-playbook bootstrap_routeros_user.yml -e ansible_user=<existing-admin>` |
| 2 | Populate the NFS rootfs / TFTP exports | `ansible-playbook populate_nfs_content.yml` |
| 3 | Create RouterOS DHCP option objects | `ansible-playbook setup_routeros_dhcp.yml` |
| 4 | Flash bootloader (auto-resolves SPI > eMMC > SD) | `ansible-playbook flash_bootloader.yml --limit rock-5b-01` |
| 4 | Force SD card target | `ansible-playbook flash_bootloader.yml --limit opi-zero3-01 -e bootloader_target=sd` |
| 5 | Full reprovision (Ansible-driven flash) | `ansible-playbook reprovision.yml --limit rock-5b-01` |
| — | Enable NFS root for a board | `ansible-playbook enable_netboot.yml --limit rock-5b-01 -e netboot_mode=nfsroot` |
| — | Enable reprovision for a board | `ansible-playbook enable_netboot.yml --limit rock-5b-01 -e netboot_mode=reprovision` |
| — | Manually revert a board to disk | `ansible-playbook disable_netboot.yml --limit rock-5b-01` |

---

## TFTP File Layout

Served from `{{ tftp_nfs_export }}` on the netboot server (default `/opt/netbootxyz/config`):

```
pxelinux.cfg/
  01-aa-bb-cc-dd-ee-ff    # per-host config, written by enable_netboot

armbian/
  orange-pi-5/
    vmlinuz               # extracted from Armbian image by populate_nfs_content
    initrd.img
    board.dtb
  orange-pi-zero-3/
    vmlinuz
    initrd.img
    board.dtb
  ...
```

Kernel/initrd/DTB are per-model (shared by all hosts of that model). Only
the rootfs is per-host.

---

## RouterOS DHCP Objects

Created once by `setup_routeros_dhcp.yml` → `routeros_dhcp/setup_options.yml`:

| Object | Name | Purpose |
|---|---|---|
| dhcp-option | armbian-tftp-server | option 66 = netboot server IP |
| dhcp-option | armbian-nfsroot-bootfile | option 67 = pxelinux.cfg path for NFS root |
| dhcp-option | armbian-reprovision-bootfile | option 67 = pxelinux.cfg path for reprovision |
| option set | armbian-nfsroot | bundles option 66 + nfsroot 67 |
| option set | armbian-reprovision | bundles option 66 + reprovision 67 |

Per board, only the static lease's `dhcp-option` field changes:

```
Netboot:  dhcp-option=armbian-nfsroot  OR  dhcp-option=armbian-reprovision
Normal:   dhcp-option=""
```

Both option sets resolve to per-host pxelinux.cfg files; the distinction
is which pxelinux LABEL the file selects (the rootfs ro/rw mode).

---

## Server IPs (single-host vs split-host)

Three on-the-wire services are involved:

1. **TFTP** (DHCP option 66) — boards fetch pxelinux.cfg / kernel / initrd / DTB from
   here. Lives at the dnsmasq IP.
2. **HTTP** (reprovision image fetch) — boards download `<model>.img.xz` from here at
   `image_server_url`. Lives at the netboot HTTP server IP.
3. **NFS** (rootfs) — boards mount `nfsroot=<ip>:<path>` baked into pxelinux.cfg.
   Lives at the NFS server IP.

In a single-host setup all three share `netboot_server_ip`. In a split-host setup
(e.g. netboot.xyz container on a macvlan network at a separate IP from the host's NFS
server), set `tftp_server_ip` (used for both TFTP and HTTP) and `nfs_server_ip`
independently. Both fall back to `netboot_server_ip` if unset.

## Image URLs

Armbian image filenames include version, kernel, and date components that
change with each release. Set them explicitly in `group_vars/all.yml`:

```yaml
armbian_image_urls:
  orange-pi-5:        "https://dl.armbian.com/orangepi5/Armbian_..."
  orange-pi-5-pro:    "https://dl.armbian.com/orangepi5pro/Armbian_..."
  orange-pi-zero-3:   "https://dl.armbian.com/orangepizero3/Armbian_..."
  ...
```

Browse `https://dl.armbian.com/<armbian_dl_dir>/` (or the `community`
GitHub releases for community-tier boards) to find the current URL.
Preflight HEAD-checks every URL; broken pins fail loudly before any work.

---

## Ansible Collections Required

Install with `ansible-galaxy collection install -r requirements.yml`:

- `community.routeros` ≥ 2.0 — RouterOS command module + network_cli cliconf (SSH)
- `ansible.posix` ≥ 1.5 — mount module for NFS content management
- `ansible.netcommon` ≥ 5.0 — network_cli connection plugin
