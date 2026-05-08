# Architecture

## What this repo is

The `david_igou.armbian_netboot` Ansible collection manages custom Armbian SD
images that PXE-first boot on the `orange-pi-5-pro`. The boards are powered
over Ethernet from a RouterOS switch, draw their DHCP from a RouterOS router
(rb5009), and NFS-root from a separate TrueNAS server. The presence of a
per-board `pxelinux.cfg/01-<MAC>` file on rb5009's TFTP server is the only
mode switch between "boot from local SD" and "boot from NFS root".
Everything else in the collection is in service of making that one toggle
reliable and idempotent.

## The v1 invariant

A board flips between disk and netboot purely because per-board
`pxelinux.cfg/01-<MAC>` is present (or absent) on rb5009. There is no
on-board state to mutate, no bootloader env to rewrite, no scripts staged
on the SBC.

This is achievable only because the U-Boot binary on the SD card has been
compiled with `BOOT_TARGETS` ordered with `pxe` first. Stock Armbian
Rockchip `current` ships PXE at position 6 of `BOOT_TARGETS`, and U-Boot's
`bootflow scan` lands on mmc1's `boot.scr` long before it tries PXE. The
`armbian_build` role in this collection exists to fix that: it patches
`include/configs/rockchip-common.h` via `armbian/build`'s
`pre_config_uboot_target__<board>_*` hook, so the resulting `.img.xz` ships
a U-Boot whose first boot target is `pxe`.

There is no on-host bootloader flashing in v1. The U-Boot binary is part of
the SD image, and the operator writes the SD card once with a tool like
`dd` or balenaEtcher before the board ever joins the network. From that
point on, the U-Boot binary is fixed. Whether the board boots from SD or
NFS depends entirely on whether rb5009 serves per-board pxelinux.cfg:

- Per-board `pxelinux.cfg/01-<MAC>` exists on rb5009's TFTP server
  (registered as a `/ip tftp` row pointing at `flash:/sbc/pxelinux.cfg/01-<MAC>`)
  → U-Boot's PXE bootmeth loads it, fetches kernel/initrd/DTB
  via TFTP from rb5009, NFS-roots from TrueNAS at `nfs_server_ip`.
- Per-board `pxelinux.cfg/01-<MAC>` is absent (no `/ip tftp` row) →
  U-Boot's PXE bootmeth fast-404s through the fallback chain
  (`01-<MAC>` → `0A0A0919` → ... → `default`, ~5–10 s total)
  → `bootflow scan` aborts the network bootdev and proceeds to
  mmc1's `boot.scr`, board boots local SD rootfs.

## External RouterOS prerequisite

The SBC RouterOS network's `next-server` field must be set to rb5009's IP for
that subnet (e.g. `10.10.9.1` for vlan9). U-Boot 2025.10's PXE bootmeth derives
the TFTP source (`serverip`) from BOOTP `siaddr` (RFC 951 next-server) — DHCP
option 66 is parsed but silently ignored for `serverip` selection. Without
`next-server`, U-Boot falls back to the DHCP server's own IP via option 54,
which is the same as rb5009 in this environment but only by coincidence; setting
`next-server` explicitly avoids the dependency.

This collection does not write `next-server` — it is owned by the operator's
separate RouterOS-config repo (e.g. `igou-ansible`'s `deploy_netboot_binaries.yml`).
See [`docs/superpowers/specs/2026-05-08-rb5009-sbc-tftp-design.md`](superpowers/specs/2026-05-08-rb5009-sbc-tftp-design.md)
for the full design context.

What this collection does write: per-model kernel/initrd/DTB and per-board
`pxelinux.cfg/01-<MAC>` to `flash:/sbc/` on rb5009, with `/ip tftp` rules
exposing each file. Plumbing-check preflight asserts the per-model rows exist
before per-board enable_netboot operations run.

## Roles

The collection is organised as **single-purpose, parameter-driven roles**.
A role enforces one external system's state given parameters; playbooks
decide which roles to invoke, with which parameters, in what order. Six
roles ship in v1.

| Role | Enforces / produces |
|---|---|
| `armbian_build` | `.img.xz` Armbian image with PXE-first U-Boot baked in, published to netboot server |
| `bootstrap_armbian` | SSH-key user with passwordless sudo on a freshly flashed board |
| `bootstrap_routeros_user` | RouterOS user / group / SSH-key state |
| `netboot_assets` | per-model rootfs template + per-host clones on TrueNAS NFS export; per-model kernel/initrd/dtb on rb5009 TFTP |
| `routeros_dhcp` | Per-board pxelinux.cfg + `/ip tftp` row on rb5009 |
| `routeros_poe` | PoE port state (on/off) on RouterOS switch ports |

The `armbian_build`, `netboot_assets`, and `routeros_dhcp` roles each own one
piece of off-board state — the build host, the netboot server's exports,
the RouterOS DHCP configuration. The two `bootstrap_*` roles bring a fresh
board or a fresh RouterOS device into a state where the other roles can
talk to them. `routeros_poe` is an optional out-of-band recovery path.

## Workflow

The v1 ordering. Each step is its own playbook, run from the collection
root. Steps marked "(Once)" or "(Once per board model)" are
setup-only; the rest are run as needed:

```
0. (Once per board model) Build custom Armbian image    → build_image.yml
1. Operator manually flashes SD card with that image    (out of band)
2. (Once)   Bootstrap RouterOS SSH user                 → bootstrap_routeros_user.yml
3. (Once per board) Bootstrap SD-rootfs SSH user        → bootstrap_armbian.yml
4.          Stage netboot assets on TrueNAS + rb5009    → stage_netboot_assets.yml
5.          Toggle board into NFS-root mode             → enable_netboot.yml
6.          Toggle board back to SD                     → disable_netboot.yml
```

Step 0 produces an image whose U-Boot tries PXE first. Step 1 is the only
manual step in the chain — the operator writes the produced `.img.xz` to
a microSD card and inserts it into the board. Steps 2–3 are one-time
RouterOS / board user setup. Step 4 stages NFS rootfs + rb5009 TFTP assets.
Steps 5–6 are the actual day-to-day toggle: add or remove per-board
pxelinux.cfg on rb5009 to send the board into NFS or back to SD.

## NFS rootfs layout

`stage_netboot_assets.yml` connects to the netboot server (TrueNAS) over SSH
and writes the per-model rootfs template + per-host rootfs clones. The control
node never NFS-mounts anything.

```
nfs_rootfs_path/
├── _templates/
│   └── orange-pi-5-pro/         per-model template (extracted from .img.xz)
└── orange-pi-5-pro-01/          per-host rootfs (cp --reflink from template,
                                 with hostname / machine-id / SSH host keys reset)
```

Per-host clones are made with `cp --reflink=auto`, which is a zero-cost
CoW snapshot on XFS, btrfs, and ZFS (one rootfs's worth of bytes
regardless of host count) and a full copy on ext4. Resetting hostname,
machine-id, and SSH host keys per-host means two same-model boards have
independent identity on the wire when they NFS-boot.

The split between `_templates/` and per-host directories is what lets a
single Armbian image extraction serve every board of that model, while
each board still gets its own writable rootfs.

## rb5009 SBC TFTP layout

The collection writes only file/`/ip tftp` state on rb5009; no DHCP
option-sets or lease mutations.

```
flash:/sbc/
├── pxelinux.cfg/
│   └── 01-<MAC>           # per-board (enable_netboot.yml writes; disable removes)
└── armbian/
    └── <model>/
        ├── vmlinuz        # per-model (stage_netboot_assets.yml writes)
        ├── initrd.img
        └── board.dtb
```

Each file has a corresponding `/ip tftp` rule with `req-filename` matching
the path U-Boot requests (e.g. `pxelinux.cfg/01-c0-74-2b-fb-4d-fd`,
`armbian/orange-pi-5-pro/vmlinuz`) and `real-filename` pointing at the
flash path. Per-board state spans the file + the row; both are added by
`enable_netboot.yml` and removed (row first) by `disable_netboot.yml`.

Per-model assets are added once by `stage_netboot_assets.yml` and persist
across enable/disable cycles. They are shared by every board of that
model.

## Out of v1 scope (deferred)

The collection's previous incarnation supported reprovisioning (Ansible
laying down a new image onto the board's persistent storage),
on-host bootloader flashing (Ansible flashing U-Boot to SPI / eMMC / SD
on a running board), and a wider catalogue of boards. v1 deliberately
narrows to a single deliverable: `orange-pi-5-pro` flipping between SD
and NFS-root via rb5009 pxelinux.cfg presence. Reprovisioning, on-host
bootloader flashing, and additional boards are deferred and will be
re-introduced post-v1 against the slimmer model.

Spec: [`superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`](superpowers/specs/2026-05-07-v1-scope-narrowing-design.md)
