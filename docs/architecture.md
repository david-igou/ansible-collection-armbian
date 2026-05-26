# Architecture

## What this repo is

The `david_igou.armbian_netboot` Ansible collection manages custom Armbian SD
images that PXE-first boot on the `orange-pi-5-pro`. The boards are powered
over Ethernet from a RouterOS switch, draw their DHCP from a RouterOS router
(rb5009), and NFS-root from a separate TrueNAS server. **Always-netboot
model:** every onboarded board always has a per-board `pxelinux.cfg/01-<MAC>`
on rb5009's TFTP server; the `default` directive inside that file selects
`nfs` versus `sd` boot (`armbian_netboot_boot_mode` in inventory). Nothing is
added or removed to flip modes — convergence rewrites the same file. Everything
else in the collection is in service of making that toggle reliable and
idempotent.

## The always-netboot invariant

There is no on-board state to mutate for routine boot-mode selection, no
bootloader env to rewrite for that purpose, and no scripts staged on the SBC
for switching NFS versus SD. The pxelinux menu labels encode both paths; the
active path is whichever label `default` names.

This is achievable only because the U-Boot binary on the SD card has been
compiled with `BOOT_TARGETS` ordered with `pxe` first. Stock Armbian
Rockchip `current` ships PXE at position 6 of `BOOT_TARGETS`, and U-Boot's
`bootflow scan` lands on mmc1's `boot.scr` long before it tries PXE. The
`image_build` role in this collection exists to fix that: it patches
`include/configs/rockchip-common.h` via `armbian/build`'s
`pre_config_uboot_target__<board>_*` hook, so the resulting `.img.xz` ships
a U-Boot whose first boot target is `pxe`.

There is no on-host bootloader flashing for this workflow. The U-Boot binary
is part of the SD image, and the operator writes the SD card once with a tool
like `dd` or balenaEtcher before the board ever joins the network. From that
point on, the U-Boot binary is fixed. Whether the board NFS-boots or uses local
SD rootfs is determined by pxelinux content on rb5009:

- Per-board `pxelinux.cfg/01-<MAC>` exists on rb5009's TFTP server
  (registered as a `/ip tftp` row pointing at `flash:/sbc/pxelinux.cfg/01-<MAC>`).
  U-Boot's PXE bootmeth always loads it and fetches kernel/initrd/DTB via TFTP
  from rb5009.
- When `default` selects the NFS label → kernel cmdline uses NFS root from
  TrueNAS at `armbian_netboot_nfs_server_ip` (see inventory /
  `armbian_netboot_nfs_rootfs_path`).
- When `default` selects the SD label → pxelinux passes a local rootfs
  identifier so the board boots from local block storage after the same PXE
  path. The cmdline is `root=LABEL=armbi_root` by default — every Armbian
  image stamps that label on the root filesystem. Boards with multiple
  drives carrying `LABEL=armbi_root` (e.g. eMMC + SD both flashed from the
  same image) set `armbian_netboot_sd_root` on the host to a more specific
  identifier such as `PARTLABEL=rootfs`, `UUID=<fs-uuid>`, or
  `PARTUUID=<part-uuid>` to disambiguate.

## External RouterOS prerequisite

The SBC RouterOS network's `next-server` field must be set to the RouterOS
router's IP for that subnet. U-Boot 2025.10's PXE bootmeth derives
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
before per-board `converge_boot_mode.yml` / `set_boot_mode.yml` operations run.

## Roles

The collection is organised as **single-purpose, parameter-driven roles**.
A role enforces one external system's state given parameters; playbooks
decide which roles to invoke, with which parameters, in what order. Nine
roles ship in the current line.

| Role | Runs on | Enforces / produces |
|---|---|---|
| `image_build` | `armbian_builders` | `.img.xz` Armbian image with PXE-first U-Boot baked in; staged to controller (companion `build_image.yml` publishes to the netboot server) |
| `image_extract` | netboot server | One rootfs template + per-model TFTP artefacts (vmlinuz / initrd / board.dtb) from a `.img.xz` (URL or local path) |
| `rootfs_clone` | netboot server | Per-host rootfs clone (reflink-copy of a template) with identity reset (hostname, machine-id, pre-generated SSH host keys) |
| `disk_image` | a board (or any host owning the target) | One whole-disk block device imaged via streaming `xz \| dd` from an `.img.xz` (URL or absolute path); mount-aware refusal guard |
| `disk_provision` | a board | Declarative GPT layout applied via `systemd-repart`, rsync `source` rootfs onto it, LABEL-keyed `/etc/fstab` regen; idempotent; supports `preserve_on_reprovision: true` per partition for state preservation |
| `pxelinux_render` | `localhost` (via `delegate_to`) | One `01-<mac>` pxelinux.cfg file in a local directory |
| `bootstrap_armbian` | a board | SSH-key user with passwordless sudo on a freshly flashed board |
| `board_boot_wait` | a board | `wait_for` TCP/22 + `wait_for_connection` SSH (no power knowledge) |
| `board_boot_verify` | a board | Asserts `ansible_mounts['/']` matches declared boot mode |

The roles are **transport-agnostic** — no RouterOS knowledge in any role. All
RouterOS-specific behaviour (TFTP / pxelinux uploads, PoE control, user bootstrap)
lives in swappable reference playbooks under `playbooks/routeros/`, selected via
`armbian_netboot_*_playbook` hooks. The image production chain (`image_build` →
`image_extract` → `rootfs_clone`) is the only role-to-role artefact flow; the
other roles consume inventory data or live-board state.

## Workflow

Each step is its own playbook (or pair), run from the collection
root. Steps marked "(Once)" or "(Once per board model)" are
setup-only; the rest are run as needed:

```
0. (Once per board model) Build custom Armbian image    → build_image.yml
1. Operator manually flashes SD card with that image    (out of band)
2. (Once)   Bootstrap RouterOS SSH user                 → routeros/bootstrap_user.yml
3. (Once per board) Bootstrap board SSH user            → bootstrap_armbian.yml
4a.         Stage NFS rootfs on netboot server          → stage_netboot_assets.yml
4b.         Stage per-model TFTP assets on rb5009       → stage_router.yml
5.          Converge board(s) to inventory boot mode    → converge_boot_mode.yml
6.          Override boot mode ad-hoc (e.g. SD)         → set_boot_mode.yml -e armbian_netboot_boot_mode=sd
```

Step 0 produces an image whose U-Boot tries PXE first. Step 1 is the only
manual step in the chain — the operator writes the produced `.img.xz` to
a microSD card and inserts it into the board. Steps 2–3 are one-time
RouterOS / board user setup. Steps 4a–4b stage NFS rootfs on the netboot server
(`stage_netboot_assets.yml`) and kernel/initrd/dtb on rb5009 (`stage_router.yml`).
Steps 5–6 are the day-to-day boot-mode operations:
per-board `pxelinux.cfg/01-<MAC>` always remains on rb5009; convergence updates
its `default` directive (and related lines) so `armbian_netboot_boot_mode` is
`nfs` or `sd`.

## NFS rootfs layout

`stage_netboot_assets.yml` connects to the netboot server (TrueNAS) over SSH
and writes the per-model rootfs template + per-host rootfs clones. The control
node never NFS-mounts anything. `stage_router.yml` stages per-model
kernel/initrd/dtb onto rb5009 (separate playbook).

```
armbian_netboot_nfs_rootfs_path/
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
│   └── 01-<MAC>           # per-board (always present; converge_boot_mode / set_boot_mode rewrite content)
└── armbian/
    └── <model>/
        ├── vmlinuz        # per-model (stage_router.yml writes)
        ├── initrd.img
        └── board.dtb
```

Each file has a corresponding `/ip tftp` rule with `req-filename` matching
the path U-Boot requests (e.g. `pxelinux.cfg/01-c0-74-2b-fb-4d-fd`,
`armbian/orange-pi-5-pro/vmlinuz`) and `real-filename` pointing at the
flash path. Per-board pxelinux files and their `/ip tftp` rows are maintained
continuously — boot-mode changes update the rendered pxelinux content (the
`default` label), not TFTP row topology.

Per-model assets are added once by `stage_router.yml` and persist across
boot-mode changes. They are shared by every board of that model.

## Scope today

The collection covers six interlocking workflows:

- **Custom image build** (`image_build` + `build_image.yml`) — Armbian
  `.img.xz` with PXE-first U-Boot baked in.
- **Netboot staging** (`image_extract` + `rootfs_clone` +
  `stage_netboot_assets.yml`) — per-model rootfs template and per-host
  identity-reset clones on the NFS server.
- **TFTP staging** (`stage_router.yml`) — per-model
  kernel/initrd/dtb and per-board pxelinux.cfg uploaded to the
  RouterOS router.
- **Boot-mode convergence** (`pxelinux_render` + `board_boot_wait` +
  `board_boot_verify` + `converge_boot_mode.yml`) — flip a board
  between NFS and SD boot by rewriting one pxelinux.cfg `default`.
- **SD imaging** (`disk_image`) — stream an `.img.xz` to a whole-disk
  block device on the board itself.
- **Local-disk reprovisioning** (`disk_provision` +
  `provision_local_disk.yml` + `reprovision_to_local.yml`) — declarative
  GPT layout via `systemd-repart`, rsync source rootfs, LABEL-keyed
  fstab; supports `preserve_on_reprovision` per partition for state
  preservation (e.g. `/var` for k3s).

Historical narrowing notes from earlier releases (when reprovisioning
was deferred) live in
[`superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`](superpowers/specs/2026-05-07-v1-scope-narrowing-design.md) —
useful for context but no longer authoritative.

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

The TFTP staging path (`stage_router.yml` → `routeros/upload_tftp_assets.yml`)
always force-removes the rb5009 copies of `vmlinuz`, `initrd.img`, and `board.dtb`
before net_put, so a re-stage always pushes the freshly-extracted kernel and
modules. (Earlier versions only re-uploaded if the file size differed, which
silently skipped a re-upload when two distinct Armbian builds happened to produce
a vmlinuz of the same byte count.)

The PXE/TFTP/DHCP plumbing in this collection is unaffected — U-Boot
loads kernel + initrd + dtb correctly; if the symptom returns,
re-running `stage_netboot_assets.yml` and `stage_router.yml` is the right first step.

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
| 1  | SD voltage-select fail           | `Card did not respond to voltage select! : -110` | RK3588S SD-controller voltage-init flake; PSU sag during cold start.                                                                        | Increase PoE drain via `-e armbian_netboot_poe_cycle_delay=20–30` (the 5 s default is too short for this board's PSU caps). Hardware-side: known-good 802.3at PSU.                                                                                                                        |
| 2  | Ethernet PHY DMA stuck           | `EQOS_DMA_MODE_SWR stuck` then `FAILED: -110`    | U-Boot `eth_eqos` driver fails GMAC DMA reset; PHY never transmits.                                                                         | Longer PoE drain helps. No in-band recovery while U-Boot is in BOOTP-retry; only a power cycle clears it. Symptomatically silent against the e2e — Phase 2 NFS-mount assertion catches the silent fall-through to SD boot.                                                |
| 3  | Mid-kernel-load SoC reset        | `Starting kernel ...` immediately followed by `DDR 9fa84341ce typ` (RK3588S DDR re-init) | SoC resets at the U-Boot → kernel handoff. PSU sag during the kernel-image checksum / read.                                                 | Out of software's reach — the kernel never executes a single instruction so cmdline flags are moot. Persistent recurrence indicates marginal PSU/SoC; physical recovery path. PR #40's verbose mode does NOT help with this signature.                                    |
| 4  | Silent post-`Starting kernel`    | `Starting kernel ...` then total serial silence  | Kernel runs but stalls before ttyS2 driver init (or after, with output suppressed). User-space init failures land here too.                 | This is the only signature `armbian_netboot_pxe_verbose=true` (PR #40) helps with. `earlycon` covers the pre-ttyS2 window; `initcall_debug` + `systemd.log_target=console` catch kernel-init and userspace-init stalls. Only effective when pxelinux selects the NFS boot label (Phase 2), not when `default` selects SD boot. |
| 5  | NetbootXYZ fallback              | `Filename 'netboot.xyz.kpxe'` followed by a normal `Starting kernel ...` from NetbootXYZ | Cascade: TFTP cannot retrieve the expected pxelinux payload (missing `/ip tftp` row, wrong `req-filename`, or path mismatch) → fall-through PXE attempts fail → U-Boot picks rb5009's default TFTP rule, which serves NetbootXYZ. Board lands in NetbootXYZ menu, no sshd. | Confirm rb5009-side via the diagnostic bundle's TFTP log slurp (PR #42). Then check that the per-board `/ip tftp` row exists with the right `req-filename` regex (`/ip tftp print where real-filename~"01-<mac>"` on rb5009). Often a downstream symptom of an earlier-stage failure (#1/#3) that just happened to trip the fallback rule. |

Software/hardware boundaries to keep in mind:

- Signatures **#1 and #2** are firmware/U-Boot-level. The kernel never
  starts. Kernel cmdline is irrelevant.
- Signature **#3** is at the U-Boot → kernel handoff. The kernel
  doesn't process any cmdline; verbose mode does not help.
- Signature **#4** is post-kernel-start. Verbose mode (`earlycon` +
  `initcall_debug` + `systemd.log_target=console`) is designed for
  this signature — but only when pxelinux's `default` selects the NFS
  boot label (Phase 2); when `default` selects SD boot, the NFS-oriented
  pxelinux kernel cmdline extras do not apply.
- Signature **#5** is a downstream symptom; the immediate fix is
  confirming rb5009's `/ip tftp` rules, but the root cause is usually
  earlier in the boot chain.

The recurring root-cause theme across #1/#3/#4 is **PSU margin during
high-current transients** (SD-controller voltage init, DDR re-init,
kernel image read). When a board exhibits multiple of these
signatures across sessions, the practical answer is hardware
inspection (PSU lead, SD seat, board swap) — not more software
mitigation.
