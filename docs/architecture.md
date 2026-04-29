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
    │                     │    │                          │
    │  ┌───────────────┐  │    │  U-Boot (SPI or SD card) │
    │  │ netboot.xyz   │  │    │                          │
    │  │ (Docker)      │◄─┼────┤  1. DHCP request        │
    │  │               │  │    │  2. If next-server set:  │
    │  │ TFTP :69      │  │    │     TFTP pxelinux.cfg   │
    │  │ HTTP :8080    │  │    │     TFTP kernel/initrd/ │
    │  └───────────────┘  │    │     DTB → boot          │
    │                     │    │  3. If no next-server:   │
    │  ┌───────────────┐  │    │     boot local disk     │
    │  │ NFS Server    │  │    └──────────────────────────┘
    │  │ /exports/     │  │
    │  │  rootfs/      │  │
    │  │  reprovision/ │  │
    │  └───────────────┘  │
    │                     │
    │  ┌───────────────┐  │
    │  │ nginx :80     │  │
    │  │ /images/      │  │
    │  │ (Armbian img) │  │
    │  └───────────────┘  │
    └─────────────────────┘
```

---

## Boot Modes

### Normal (disk boot)

RouterOS has no PXE DHCP options assigned to the board's static lease.
U-Boot starts from SPI (or SD card), DHCP returns no next-server, PXE
attempt fails, and U-Boot falls through to NVMe or eMMC.

### NFS Root (diskless)

The board boots a full Armbian rootfs served over NFS. Useful for testing,
maintenance, or running the board completely off-network storage.

1. Ansible `enable_netboot.yml -e netboot_mode=nfsroot` runs
2. RouterOS lease gets `dhcp-option=armbian-nfsroot`
3. Board reboots → U-Boot DHCP → gets next-server + boot file path
4. U-Boot fetches `pxelinux.cfg/01-<mac>` → downloads kernel, initrd, DTB
5. Board boots into Armbian on NFS at `/exports/rootfs/<model>` (read-only)

### Reprovision

Same PXE flow as NFS root, but the kernel cmdline includes `reprovision=1`
and the root is the read-write reprovision export. On boot, systemd starts
`reprovision.service`, which:

1. Reads `/etc/reprovision.conf` (credentials on NFS server, not board disk)
2. Downloads `<model>.img.xz` from the nginx image server on the netboot host
3. Flashes it to NVMe (`/dev/nvme0n1`) or eMMC (`/dev/mmcblk0`)
4. Calls the RouterOS REST API to clear `dhcp-option` from the board's lease
5. Reboots — board comes up from the freshly flashed disk

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
- The card can remain inserted permanently; removing it makes the board
  fall back to eMMC U-Boot (if present) which defaults to disk-first

**Preparing the SD card** (run once per card, on the netboot server):

```bash
ansible-playbook playbooks/prepare_sd_card.yml \
  -e board_model=rock-5a \
  -e sd_card_device=/dev/sdb
```

The playbook reads the U-Boot binary and env offset from the Armbian rootfs
already extracted by `setup_server.yml`, so no additional downloads are needed.

---

## Trigger Reference

| Goal | Command |
|---|---|
| Enable reprovision for one board | `ansible-playbook enable_netboot.yml --limit rock-5b-01 -e netboot_mode=reprovision` |
| Enable NFS root for all boards | `ansible-playbook enable_netboot.yml -e netboot_mode=nfsroot` |
| Manually revert a board to disk | `ansible-playbook disable_netboot.yml --limit rock-5b-01` |
| Full reprovision workflow | `ansible-playbook reprovision.yml --limit rock-5b-01` |
| Prepare SD card (non-SPI board) | `ansible-playbook prepare_sd_card.yml -e board_model=rock-5a -e sd_card_device=/dev/sdb` |

---

## TFTP File Layout

Served from `/opt/netbootxyz/config/` on the netboot server:

```
pxelinux.cfg/
  01-aa-bb-cc-dd-ee-ff    # per-board config, generated by enable_netboot
  nfsroot-default         # shared fallback — NFS root mode
  reprovision-default     # shared fallback — reprovision mode

armbian/
  orange-pi-5/
    vmlinuz               # extracted from Armbian image by setup_server
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

```
/exports/
  rootfs/
    orange-pi-5/          # read-only Armbian rootfs
    rock-5b/
    ...
  reprovision/
    orange-pi-5/          # read-write; holds reprovision.sh + systemd unit
    rock-5b/
    ...
```

---

## RouterOS DHCP Objects

Created once by `setup_server.yml` → `routeros_dhcp/setup_options.yml`:

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

---

## Ansible Collections Required

Install with `ansible-galaxy collection install -r ansible/requirements.yml`:

- `community.routeros` ≥ 2.0 — RouterOS API/command modules
- `community.docker` ≥ 3.0 — docker_compose_v2 module
- `ansible.netcommon` ≥ 5.0 — network_cli connection plugin
