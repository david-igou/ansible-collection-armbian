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
| `routeros_sbc_tftp` | Per-board pxelinux.cfg + `/ip tftp` row on rb5009 |
| `routeros_poe` | PoE port state (on/off) on RouterOS switch ports |

The `armbian_build`, `netboot_assets`, and `routeros_sbc_tftp` roles each own one
piece of off-board state — the build host, the netboot server's exports,
and rb5009's SBC TFTP layout (per-board pxelinux.cfg + `/ip tftp` rows). The
two `bootstrap_*` roles bring a fresh board or a fresh RouterOS device into
a state where the other roles can talk to them. `routeros_poe` is an
optional out-of-band recovery path.

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

## Known issues

### "kernel lacks NFS v3 support" usually means a stale vmlinuz

If the initramfs's `nfsmount` reports `mount: the kernel lacks NFS v3
support` while looping on `Begin: Retrying nfs mount`, the cause is
almost always a **kernel/module version mismatch** between the vmlinuz
served by rb5009 and the `/lib/modules/<version>/` tree carried by the
freshly-staged initramfs and NFS rootfs. modprobe inside the initramfs
walks `/lib/modules/$(uname -r)/`, finds nothing if the kernel version
on rb5009 doesn't match the staged module tree, and so nfsv3.ko never
gets loaded — even though it's physically present in the initramfs at
the *other* kernel version's path.

`stage_netboot_assets.yml` always force-removes the rb5009 copies of
`vmlinuz`, `initrd.img`, and `board.dtb` before net_put, so a re-stage
always pushes the freshly-extracted kernel and modules. (Earlier
versions only re-uploaded if the file size differed, which silently
skipped a re-upload when two distinct Armbian builds happened to
produce a vmlinuz of the same byte count.)

The PXE/TFTP/DHCP plumbing in this collection is unaffected — U-Boot
loads kernel + initrd + dtb correctly; if the symptom returns,
re-running `stage_netboot_assets.yml` is the right first step.

### Hardware/firmware failure signatures observed on `orange-pi-5-pro`

When `playbooks/test_hardware_e2e.yml` reports an opaque
`wait_for_connection: timed out` for `orange-pi-5-pro`, the underlying
cause is almost always one of these five distinct hardware/firmware
failure modes — not a software regression in this collection. Each
signature has a unique serial-side fingerprint; grep the `socat`
capture (or whichever serial log the e2e wrote) for the fragment in
column 2 to disambiguate. Issue
[#38](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/38)
carries the full per-signature stanza (frequency, triggers, false
friends, history) — this table is the fast lookup.

| #  | Short name                       | Serial fingerprint (literal grep target)         | Root cause                                                                                                                                  | Mitigation                                                                                                                                                                                                                                                                |
|----|----------------------------------|--------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | SD voltage-select fail           | `Card did not respond to voltage select! : -110` | RK3588S SD-controller voltage-init flake; PSU sag during cold start.                                                                        | Increase PoE drain via `-e poe_cycle_delay=20–30` (the 5 s default is too short for this board's PSU caps). Hardware-side: known-good 802.3at PSU.                                                                                                                        |
| 2  | Ethernet PHY DMA stuck           | `EQOS_DMA_MODE_SWR stuck` then `FAILED: -110`    | U-Boot `eth_eqos` driver fails GMAC DMA reset; PHY never transmits.                                                                         | Longer PoE drain helps. No in-band recovery while U-Boot is in BOOTP-retry; only a power cycle clears it. Symptomatically silent against the e2e — Phase 2 NFS-mount assertion catches the silent fall-through to SD boot.                                                |
| 3  | Mid-kernel-load SoC reset        | `Starting kernel ...` immediately followed by `DDR 9fa84341ce typ` (RK3588S DDR re-init) | SoC resets at the U-Boot → kernel handoff. PSU sag during the kernel-image checksum / read.                                                 | Out of software's reach — the kernel never executes a single instruction so cmdline flags are moot. Persistent recurrence indicates marginal PSU/SoC; physical recovery path. PR #40's verbose mode does NOT help with this signature.                                    |
| 4  | Silent post-`Starting kernel`    | `Starting kernel ...` then total serial silence  | Kernel runs but stalls before ttyS2 driver init (or after, with output suppressed). User-space init failures land here too.                 | This is the only signature `pxelinux_verbose=true` (PR #40) helps with. `earlycon` covers the pre-ttyS2 window; `initcall_debug` + `systemd.log_target=console` catch kernel-init and userspace-init stalls. Only effective on the PXE path (Phase 2), not Phase 1 SD boot. |
| 5  | NetbootXYZ fallback              | `Filename 'netboot.xyz.kpxe'` followed by a normal `Starting kernel ...` from NetbootXYZ | Cascade: per-board `pxelinux.cfg/01-<MAC>` lookup fails → fall-through PXE attempts ALL fail → U-Boot picks rb5009's default tftp rule, which serves NetbootXYZ. Board lands in NetbootXYZ menu, no sshd. | Confirm rb5009-side via the diagnostic bundle's TFTP log slurp (PR #42). Then check that the per-board `/ip tftp` row exists with the right `req-filename` regex (`/ip tftp print where real-filename~"01-<mac>"` on rb5009). Often a downstream symptom of an earlier-stage failure (#1/#3) that just happened to trip the fallback rule. |

Software/hardware boundaries to keep in mind:

- Signatures **#1 and #2** are firmware/U-Boot-level. The kernel never
  starts. Kernel cmdline is irrelevant.
- Signature **#3** is at the U-Boot → kernel handoff. The kernel
  doesn't process any cmdline; verbose mode does not help.
- Signature **#4** is post-kernel-start. Verbose mode (`earlycon` +
  `initcall_debug` + `systemd.log_target=console`) is designed for
  this signature — but only on the PXE path (Phase 2), since
  pxelinux.cfg is not consulted on Phase 1 SD boot.
- Signature **#5** is a downstream symptom; the immediate fix is
  confirming rb5009's `/ip tftp` rules, but the root cause is usually
  earlier in the boot chain.

The recurring root-cause theme across #1/#3/#4 is **PSU margin during
high-current transients** (SD-controller voltage init, DDR re-init,
kernel image read). When a board exhibits multiple of these
signatures across sessions, the practical answer is hardware
inspection (PSU lead, SD seat, board swap) — not more software
mitigation.
