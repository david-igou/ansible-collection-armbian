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
    │   Netboot Server    │    │       Board (RK3588)     │
    │  (already running)  │    │                          │
    │                     │    │  U-Boot (SPI or SD card) │
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
    │  └───────────────┘  │    │                          │
    └─────────────────────┘    │  Mounts NFS exports,     │
                               │  writes content; SSHes   │
                               │  into NFS-booted boards  │
                               │  to drive reprovision    │
                               └──────────────────────────┘
```

---

## Boot Modes

### Normal (disk boot)

RouterOS has no PXE DHCP options assigned to the board's static lease.
U-Boot starts from SPI (or SD card), DHCP returns no next-server, PXE
attempt fails, and U-Boot falls through to NVMe or eMMC.

### NFS Root (diskless)

The board boots a full Armbian rootfs served over NFS (read-only mount).
Useful for testing, maintenance, or running the board completely off-network
storage.

1. `enable_netboot.yml -e netboot_mode=nfsroot` runs
2. RouterOS lease gets `dhcp-option=armbian-nfsroot`
3. Board reboots → U-Boot DHCP → gets next-server + boot file path
4. U-Boot fetches `pxelinux.cfg/01-<mac>` → downloads kernel, initrd, DTB
5. Board boots into Armbian on NFS at `/exports/rootfs/<model>` (ro)

### Reprovision

Same PXE flow as NFS root, but the rootfs is mounted read-write to give
systemd full write access. Ansible SSHes into the board after it comes up
and drives the flash directly — no scripts are staged on the board.

1. `reprovision.yml` runs
2. RouterOS lease gets `dhcp-option=armbian-reprovision`
3. Board reboots → PXE boots into NFS rootfs (rw mount)
4. Ansible waits for SSH (`root` / `armbian_default_password`)
5. Ansible downloads `.img.xz` from netboot.xyz HTTP server to `/tmp`
6. Ansible flashes the image to NVMe/eMMC with `xz | dd`
7. Ansible clears `dhcp-option` on RouterOS from the control node
8. Ansible reboots the board → comes up from freshly flashed disk
9. Ansible asserts root filesystem is no longer NFS

---

## Bootloader: Two Paths

The board's boot behaviour (disk vs PXE) is controlled entirely by RouterOS
DHCP options regardless of which bootloader path is used. The only difference
is where U-Boot lives.

### Path 1 — SPI flash (Orange Pi 5, Orange Pi 5 Pro, Orange Pi 5 Max, Rock 5B)

```
SPI flash
└── U-Boot (Armbian linux-u-boot-current-<board>)
      ├── DHCP → next-server set   → PXE boot (nfsroot or reprovision)
      └── DHCP → no next-server    → local disk (NVMe / eMMC)
```

- U-Boot is flashed to SPI once via `flash_bootloader.yml`
- No physical intervention ever needed to switch boot mode
- RouterOS DHCP change is the sole trigger

### Path 2 — SD card (Rock 5A, and Rock 5B if SPI socket is unpopulated)

```
SD card (permanent, inserted into board)
└── U-Boot  (boot_targets = pxe dhcp mmc0 nvme0 mmc1)
      ├── DHCP → next-server set   → PXE boot (nfsroot or reprovision)
      └── DHCP → no next-server    → local disk (NVMe / eMMC)
```

- SD card is prepared once via `prepare_sd_card.yml` and physically inserted
- The SD card contains **only U-Boot** — no OS, no partitions
- U-Boot's environment on the card sets `boot_targets` to try PXE first
- When DHCP provides no next-server, PXE fails and the board boots from disk
- The card can remain inserted permanently

**Preparing the SD card** (run once per card, on the Ansible control node):

```bash
ansible-playbook playbooks/prepare_sd_card.yml \
  -e board_model=rock-5a \
  -e sd_card_device=/dev/sdb
```

The playbook reads the U-Boot binary and env offset from the Armbian rootfs
already extracted by `setup_netboot.yml`, so no additional downloads are needed.

---

## How NFS Content is Managed

This repo does not configure the netboot server — it only populates the NFS
exports that netboot.xyz and the boards consume. All writes happen through
NFS mounts on the Ansible control node:

```
Control node (ansible-playbook runs here)
  │
  ├── mounts {{ netboot_server_ip }}:{{ tftp_nfs_export }}  → /mnt/netboot/tftp/
  │     Writes: pxelinux.cfg/01-<mac>, armbian/<model>/{vmlinuz,initrd,dtb}
  │
  ├── mounts {{ netboot_server_ip }}:{{ nfs_rootfs_path }}/<model>  → /mnt/netboot/rootfs/<model>/
  │     Writes: full Armbian rootfs (rsync from extracted image)
  │     Shared by both nfsroot (ro) and reprovision (rw) boot modes
  │
  └── mounts {{ netboot_server_ip }}:{{ nfs_assets_export }}  → /mnt/netboot/assets/
        Writes: images/<model>.img.xz  (served via netboot.xyz HTTP :8080)
```

No SSH access to the netboot server is required for any content operation.

A single NFS rootfs export serves both boot modes. The nfsroot pxelinux label
mounts it `ro`; the reprovision label mounts it `rw`. The NFS server export
itself must be configured with `rw,no_root_squash`.

---

## Trigger Reference

| Goal | Command |
|---|---|
| Populate NFS and set up RouterOS DHCP objects | `ansible-playbook setup_netboot.yml` |
| Enable NFS root for a board | `ansible-playbook enable_netboot.yml --limit rock-5b-01 -e netboot_mode=nfsroot` |
| Enable reprovision for a board | `ansible-playbook enable_netboot.yml --limit rock-5b-01 -e netboot_mode=reprovision` |
| Full reprovision (Ansible-driven flash) | `ansible-playbook reprovision.yml --limit rock-5b-01` |
| Manually revert a board to disk | `ansible-playbook disable_netboot.yml --limit rock-5b-01` |
| Prepare SD card (non-SPI board) | `ansible-playbook prepare_sd_card.yml -e board_model=rock-5a -e sd_card_device=/dev/sdb` |

---

## TFTP File Layout

Served from `{{ tftp_nfs_export }}` on the netboot server (default `/opt/netbootxyz/config`):

```
pxelinux.cfg/
  01-aa-bb-cc-dd-ee-ff    # per-board config, written by enable_netboot

armbian/
  orange-pi-5/
    vmlinuz               # extracted from Armbian image by setup_netboot
    initrd.img
    board.dtb
  rock-5b/
    vmlinuz
    initrd.img
    board.dtb
  ...
```

---

## NFS Export Layout

A single rootfs export per board model serves both nfsroot and reprovision modes:

```
/exports/
  rootfs/
    orange-pi-5/          # Armbian rootfs; mounted ro for nfsroot, rw for reprovision
    rock-5b/
    ...
```

---

## RouterOS DHCP Objects

Created once by `setup_netboot.yml` → `routeros_dhcp/setup_options.yml`:

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

Both option sets point to the same NFS rootfs; the distinction is that
`armbian-reprovision` selects the pxelinux label that mounts the rootfs `rw`.

---

## Image URLs

Armbian image filenames include version, kernel, and date components that
change with each release. Set them explicitly in `group_vars/all.yml`:

```yaml
armbian_image_urls:
  orange-pi-5:     "https://dl.armbian.com/orangepi5/Armbian_25.x_..."
  orange-pi-5-pro: "https://dl.armbian.com/orangepi5-pro/Armbian_25.x_..."
  orange-pi-5-max: "https://dl.armbian.com/orangepi5-max/Armbian_25.x_..."
  rock-5b:         "https://dl.armbian.com/rock-5b/Armbian_25.x_..."
  rock-5a:         "https://dl.armbian.com/rock-5a/Armbian_25.x_..."
```

Browse `https://dl.armbian.com/<board>/` to find the current URL. Prefer
the `server` or `minimal` variant (`bookworm` recommended for stability).

Set them in `inventory/group_vars/all.yml`.

---

## Ansible Collections Required

Install with `ansible-galaxy collection install -r requirements.yml`:

- `community.routeros` ≥ 2.0 — RouterOS API/command modules
- `ansible.posix` ≥ 1.5 — mount module for NFS content management
- `ansible.netcommon` ≥ 5.0 — network_cli connection plugin
