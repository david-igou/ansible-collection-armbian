# Architecture

## What this repo is

The `david_igou.armbian_netboot` Ansible collection manages custom Armbian SD
images that PXE-first boot on the `orange-pi-5-pro`. The boards are powered
over Ethernet from a RouterOS switch, draw their DHCP from a RouterOS router,
and netboot from a separate netboot.xyz + NFS server. A single field on the
RouterOS static lease — the `dhcp-option` — is the only mode switch between
"boot from local SD" and "boot from NFS root". Everything else in the
collection is in service of making that one toggle reliable and idempotent.

## The v1 invariant

A board flips between disk and netboot purely because of a DHCP option that
its lease carries. There is no on-board state to mutate, no bootloader env
to rewrite, no scripts staged on the SBC.

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
NFS depends entirely on what RouterOS hands it via DHCP:

- DHCP lease has the `armbian-nfsroot` option set assigned → per-board
  `pxelinux.cfg/01-<MAC>` exists on the netboot server's TFTP root →
  U-Boot's PXE bootmeth loads it, fetches kernel/initrd/DTB,
  NFS-roots from the netboot server.
- DHCP lease has no option set assigned → per-board `pxelinux.cfg/01-<MAC>`
  is absent → U-Boot's PXE bootmeth fast-404s through the fallback
  chain (`01-<MAC>` → `0A0A0919` → ... → `default`, ~5–10 s total)
  → `bootflow scan` aborts the network bootdev and proceeds to
  mmc1's `boot.scr`, board boots local SD rootfs.

## External RouterOS prerequisite

The SBC RouterOS network's `next-server` field must be set to the
TFTP server's IP. U-Boot 2025.10's PXE bootmeth derives the TFTP
source (`serverip`) from BOOTP `siaddr` (RFC 951 next-server) — DHCP
option 66 is parsed but silently ignored for `serverip` selection.
Without `next-server`, U-Boot falls back to the DHCP server's own IP
(via option 54), which has no TFTP daemon, and every netboot attempt
hangs in retries until the chip's watchdog resets the board.

This collection does not write `next-server`; it is owned by the
operator's separate RouterOS-config repo. The
`routeros_dhcp/preflight_next_server` task asserts the value is set
correctly before any play that depends on netboot working
(`setup_routeros_dhcp.yml`, `enable_netboot.yml`,
`disable_netboot.yml`, `stage_netboot_assets.yml`). The fail message
names the exact RouterOS command to run if the assertion fires.

The required inventory variable is `routeros_sbc_network_address`
(CIDR; e.g. `"10.10.9.0/24"`). See
[`docs/superpowers/specs/2026-05-07-bootflow-pxe-first-design.md`](superpowers/specs/2026-05-07-bootflow-pxe-first-design.md)
for the full design context.

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
| `netboot_assets` | rootfs / TFTP / pxelinux content under server exports |
| `routeros_dhcp` | Shared DHCP option set (`armbian-nfsroot`) + per-lease assignment on RouterOS |
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
4. (Once)   Create RouterOS DHCP option objects         → setup_routeros_dhcp.yml
5.          Populate NFS exports for a board            → stage_netboot_assets.yml
6.          Toggle board into NFS-root mode             → enable_netboot.yml
7.          Toggle board back to SD                     → disable_netboot.yml
```

Step 0 produces an image whose U-Boot tries PXE first. Step 1 is the only
manual step in the chain — the operator writes the produced `.img.xz` to
a microSD card and inserts it into the board. Steps 2–4 are one-time
RouterOS / board / DHCP option-set setup. Steps 5–7 are the actual
day-to-day toggle: populate the NFS exports for a board, then flip the
RouterOS DHCP option to send it into NFS or back to SD.

## NFS content layout

`stage_netboot_assets.yml` connects to the netboot server over SSH and
writes three kinds of content under the server's exports. The control
node never NFS-mounts anything.

```
nfs_rootfs_path/
├── _templates/
│   └── orange-pi-5-pro/         per-model template (extracted from .img.xz)
└── orange-pi-5-pro-01/          per-host rootfs (cp --reflink from template,
                                 with hostname / machine-id / SSH host keys reset)

tftp_nfs_export/
├── armbian/
│   └── orange-pi-5-pro/
│       ├── vmlinuz              per-model TFTP content (kernel, initrd, DTB)
│       ├── initrd.img
│       └── *.dtb
└── pxelinux.cfg/
    └── 01-aa-bb-cc-dd-ee-ff     per-board boot config, pointing at this host's
                                 per-host rootfs export
```

Per-host clones are made with `cp --reflink=auto`, which is a zero-cost
CoW snapshot on XFS, btrfs, and ZFS (one rootfs's worth of bytes
regardless of host count) and a full copy on ext4. Resetting hostname,
machine-id, and SSH host keys per-host means two same-model boards have
independent identity on the wire when they NFS-boot.

The split between `_templates/` and per-host directories is what lets a
single Armbian image extraction serve every board of that model, while
each board still gets its own writable rootfs.

## RouterOS object set

`setup_routeros_dhcp.yml` creates exactly three RouterOS objects, once,
shared by every board:

- `dhcp-option armbian-tftp-server` — option 66, value is the TFTP
  server's IP address.
- `dhcp-option armbian-nfsroot-bootfile` — option 67, value is
  `pxelinux.cfg/nfsroot-default` (a stub that hands off to the
  per-board `pxelinux.cfg/01-<mac>` config).
- `dhcp-option set armbian-nfsroot` — bundles the two `dhcp-option`
  entries above.

Per-board state spans two things: the `dhcp-option-set` field on the
static lease (RouterOS) and the per-board `pxelinux.cfg/01-<MAC>`
file (netboot server). `enable_netboot.yml` writes the file and
assigns the option set; `disable_netboot.yml` removes the file and
clears the option set. File presence is the load-bearing signal —
without a per-board pxelinux.cfg, U-Boot's PXE bootmeth fast-404s
through the fallback chain and proceeds to MMC. The option-set
assignment is now ornamental but kept for symmetry with the
historical control surface.

## Out of v1 scope (deferred)

The collection's previous incarnation supported reprovisioning (Ansible
laying down a new image onto the board's persistent storage),
on-host bootloader flashing (Ansible flashing U-Boot to SPI / eMMC / SD
on a running board), and a wider catalogue of boards. v1 deliberately
narrows to a single deliverable: `orange-pi-5-pro` flipping between SD
and NFS-root via DHCP. Reprovisioning, on-host bootloader flashing, and
additional boards are deferred and will be re-introduced post-v1
against the slimmer model.

Spec: [`superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`](superpowers/specs/2026-05-07-v1-scope-narrowing-design.md)
