# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The `david_igou.armbian_netboot` Ansible collection for managing Armbian-based
ARM SBCs end-to-end. PXE-netboot is a workflow built on the collection's
primitives — it is not the framing.

Per-board pxelinux.cfg presence on rb5009's TFTP server is the sole trigger for
switching a board between disk boot and netboot. The netboot server (TrueNAS,
running NFS) is assumed to already be running; this collection manages its NFS
export contents, rb5009's SBC TFTP layout, PoE power state, and (via
`armbian_build`) the custom Armbian images those workflows consume.

## Mental model: roles + workflow playbooks

**Roles are single-purpose, parameter-driven state enforcers. Playbooks compose
them into workflows.** A role asks "given these inputs, is the world in the
desired state, and if not, make it so." It does not decide intent; callers do.
A playbook decides which roles to invoke, against which inventory, with which
parameters, in what order.

| Role | Enforces / produces |
|---|---|
| `armbian_build` | `.img.xz` Armbian image with PXE-first U-Boot baked in, published to netboot server |
| `bootstrap_armbian` | SSH-key user with passwordless sudo on a freshly flashed board |
| `bootstrap_routeros_user` | RouterOS user / group / SSH-key state |
| `netboot_assets` | rootfs / TFTP / pxelinux content under server exports |
| `routeros_dhcp` | Per-board pxelinux.cfg + `/ip tftp` row on rb5009 |
| `routeros_poe` | PoE port state (on/off) on RouterOS switch ports |

## ✅ Status: v1 = orangepi5pro netboot capability only

This collection is currently scoped to a single deliverable: a custom
Armbian SD image for `orangepi5pro` whose U-Boot tries PXE first, so
adding/removing per-board pxelinux.cfg on rb5009 switches the board between
an NFS rootfs and the local SD rootfs. v1 explicitly does not include
reprovisioning, on-host bootloader flashing, or any board other than
`orangepi5pro`. Reprovisioning and on-host bootloader flashing have
been deleted from the repo, not deferred-in-place; they will be
re-introduced post-v1 against the slimmer model.

The "what runs over NFS / why" question is deferred — v1 just
demonstrates that a board can be flipped between SD and NFS via rb5009's
TFTP layout. See `playbooks/test_hardware_e2e.yml` for the assertion harness.

Spec: [`docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`](docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md)

## Collection structure

```
david_igou/armbian_netboot/   (this repo root)
├── galaxy.yml                # Collection metadata
├── ansible.cfg               # Ansible config for direct-from-root runs
├── requirements.yml          # External collection dependencies
├── meta/runtime.yml          # Minimum Ansible version (>=2.15)
├── vars/
│   └── boards.yml            # Per-board metadata (v1: orange-pi-5-pro only)
├── roles/
│   ├── armbian_build/             # Build custom .img.xz on armbian_builders host
│   ├── bootstrap_armbian/         # Provision passwordless-sudo SSH-key user
│   ├── bootstrap_routeros_user/   # Provision RouterOS user/group/SSH keys
│   ├── netboot_assets/               # Populate NFS exports (preflight + per-model + per-host)
│   ├── routeros_dhcp/             # RouterOS DHCP option management (nfsroot mode)
│   └── routeros_poe/              # PoE power control via RouterOS switch
├── playbooks/
│   ├── bootstrap_armbian.yml        # (0) Provision SSH-key user on flashed boards
│   ├── bootstrap_routeros_user.yml  # (1) Provision RouterOS user/group/SSH keys
│   ├── stage_netboot_assets.yml     # (2) Populate NFS rootfs + rb5009 TFTP content
│   ├── build_image.yml              # Build custom Armbian .img.xz for orangepi5pro
│   ├── enable_netboot.yml           # Toggle board into NFS-root mode
│   ├── disable_netboot.yml          # Revert to disk boot
│   ├── poe_control.yml              # PoE power on/off/cycle via switch
│   ├── test_hardware_e2e.yml        # SD → NFS → SD assertion harness
│   └── tasks/
│       └── diagnostic_bundle.yml
├── .inventory/               # Real inventory (gitignored)
├── inventory/                # Documentation-only sample inventory
│   ├── hosts.yml             # orange-pi-5-pro example only
│   └── group_vars/
│       ├── all.yml           # Global vars (image URLs, NFS paths, etc.)
│       └── routeros.yml      # network_cli connection plumbing
└── docs/
    ├── architecture.md
    ├── routeros-setup.md
    └── superpowers/specs/    # Design specs (this repo's history of decisions)
```

## Running playbooks

Run from the collection root:

```bash
# Install required external collections first
ansible-galaxy collection install -r requirements.yml

# (0) Build the custom Armbian image for orange-pi-5-pro on a builder
# host. Publishes the resulting .img.xz to the netboot server's HTTP
# assets directory. Re-run after changes to the patch table or pinned
# armbian/build ref.
ansible-playbook playbooks/build_image.yml

# (1) Bootstrap a freshly flashed Armbian board: create the inventory's
# `ansible_user` with passwordless sudo + SSH-key auth.
ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01

# (2) Bootstrap the RouterOS SSH user (one-time, against an existing admin user).
ansible-playbook playbooks/bootstrap_routeros_user.yml \
  -e ansible_user=<existing-admin>

# (3) Stage netboot assets on TrueNAS (NFS rootfs) + rb5009 (TFTP kernel/initrd/dtb).
ansible-playbook playbooks/stage_netboot_assets.yml

# Toggle a board into NFS-root mode (board reboots immediately).
ansible-playbook playbooks/enable_netboot.yml --limit orange-pi-5-pro-01

# Revert a board to disk boot.
ansible-playbook playbooks/disable_netboot.yml --limit orange-pi-5-pro-01

# Power cycle a board via its upstream RouterOS switch.
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 -e poe_action=cycle

# Hardware E2E test: toggle a board through SD → nfsroot → SD and assert
# each transition. Single board via --limit. Optional serial capture
# with `-e capture_serial=true` (see playbook header).
ansible-playbook playbooks/test_hardware_e2e.yml --limit orange-pi-5-pro-01
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
- `sbc_tftp_flash_dir` (overridable) — top-level dir on rb5009's flash for SBC TFTP
  content. Default `sbc`. Used as `flash:/<sbc_tftp_flash_dir>/...` in `/file` paths
  and as the prefix of `real-filename` in `/ip tftp` rules.
- `sbc_tftp_cache_dir` (overridable) — control-node cache where kernel/initrd/dtb
  fetched from TrueNAS get stashed before `net_put` to rb5009. Default
  `{{ playbook_dir }}/../.cache/sbc-tftp/` (gitignored).
- `nfs_server_ip` (optional) — overrides `netboot_server_ip` for the NFS role.
- `armbian_default_password` — Armbian NFS root SSH password (default `1234`); encrypt with vault
- `armbian_image_urls` — full `.img.xz` URL per board model. In v1 this points at
  the locally-published custom build under `image_server_url/<board>/<file>.img.xz`
  (the URL `playbooks/build_image.yml` publishes to).
- **External RouterOS prerequisite**: the SBC subnet's `next-server` must be set to
  rb5009's IP for that subnet (e.g. `10.10.9.1` for vlan9). This is owned by your
  separate RouterOS-config repo (e.g. igou-ansible's `deploy_netboot_binaries.yml`)
  and not asserted by this collection. Without it, U-Boot can't reach rb5009's TFTP
  daemon to fetch per-board pxelinux.cfg + per-model kernel/initrd/dtb.
- `nfs_assets_export` (overridable) — HTTP server's document root. Default
  `/mnt/ssd/containers/netbootxyz/assets` matches netboot.xyz container's nginx root.

`inventory/group_vars/routeros.yml` only pins the network_cli connection plumbing
(`ansible_connection`, `ansible_network_os`); it intentionally does **not** set
`ansible_user` / `ansible_port` — those are per-host values in `hosts.yml`.

**Three RouterOS groups in `inventory/hosts.yml`**:

- `routeros_routers` — devices that run a DHCP server. All per-board plays
  (`enable_netboot.yml`, `disable_netboot.yml`) target this group; the
  DHCP-mutating commands would fail on switches.
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
value must exactly match a key in `vars/boards.yml`.

For PoE-powered boards, also set `poe_switch` (inventory hostname of the RouterOS switch
providing power) and `poe_port` (interface name on that switch, e.g. `ether3`). These are
required by `playbooks/poe_control.yml`.

## Architecture

**The intended invariant**: per-board pxelinux.cfg presence on rb5009's TFTP server
is the *only* control surface for switching boot mode. U-Boot tries PXE first and
falls through to disk when no `pxelinux.cfg/01-<MAC>` is registered for the board.

This invariant is delivered by custom Armbian images built via the `armbian_build`
role — stock Armbian Rockchip `current` ships PXE at position 6 in `BOOT_TARGETS`
and `bootflow scan` lands on mmc1's `boot.scr` first, so a stock image cannot
deliver the invariant. The PXE-first ordering must come from the U-Boot binary's
compile-time `BOOT_TARGETS`, which the `armbian_build` role patches via
`armbian/build`'s `pre_config_uboot_target__<board>_*` hook before U-Boot is
configured.

### Pre-flight validation
`stage_netboot_assets.yml` runs `roles/netboot_assets/tasks/preflight.yml` first, which
HEAD-checks every board's `armbian_image_urls` entry (failing on 4xx/dead mirror)
before any image download or NFS write.

## How netboot content is managed

`stage_netboot_assets.yml` writes two pieces of state. First, it connects to the
netboot server (TrueNAS) over SSH (`hosts: netboot_server`, `become: true`) and
operates on `nfs_rootfs_path` + `nfs_assets_export` directly as filesystem paths —
no NFS client mount on the control node is required. Then it stages per-model
kernel/initrd/dtb to rb5009 by `net_put`-ing files into `flash:/<sbc_tftp_flash_dir>/`
and registering corresponding `/ip tftp` rules.

Inside `nfs_rootfs_path` two layouts coexist:

```
nfs_rootfs_path/
├── _templates/
│   └── orange-pi-5-pro/    per-model template (extracted from .img.xz)
└── orange-pi-5-pro-01/     per-host clone of _templates/orange-pi-5-pro
```

Per-host clones are made with `cp --reflink=auto`, which is a zero-cost CoW snapshot on
XFS, btrfs, and ZFS (one rootfs's worth of bytes regardless of host count) and a full copy
on ext4. Hostname, machine-id, and SSH host keys are reset per-host so two same-model
boards have independent identity on the wire — see `roles/netboot_assets/tasks/per_host.yml`.
The `pxelinux.cfg/01-<mac>` files (on rb5009) point each board at its own per-host export.

`enable_netboot.yml` renders per-board `pxelinux.cfg/01-<mac>` content locally and
`net_put`s it to rb5009's flash, then registers a `/ip tftp` row exposing that file.
`disable_netboot.yml` removes the row first, then the file. The control node never
NFS-mounts anything and never SSHes to the netboot server during enable/disable —
rb5009 is the entire control surface for boot-mode toggles.

## Where things run

| Playbook | Runs on |
|---|---|
| `bootstrap_armbian.yml` | **boards** (connects as root with `armbian_default_password`; idempotent) |
| `bootstrap_routeros_user.yml` | RouterOS (router + switches via `routeros_netboot`) |
| `stage_netboot_assets.yml` | **netboot server** (image extraction, NFS rootfs) + **rb5009** (kernel/initrd/dtb via `net_put` + `/ip tftp` registration) |
| `build_image.yml` | **`armbian_builders`** (Docker-capable build host); publishes to **netboot server** over SSH |
| `enable_netboot.yml` / `disable_netboot.yml` | **rb5009** (per-board pxelinux.cfg + `/ip tftp` row) + **boards** (reboot trigger) |
| `poe_control.yml` | **boards** (delegated to `routeros_switches` via `poe_switch` hostvar) |
| `test_hardware_e2e.yml` | **boards** + **rb5009** (delegated) + RouterOS switch (PoE, delegated) |

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
  `/usr/lib/linux-u-boot-<branch>-<board>` (segments swapped). Heads-up
  for any future board onboarding that needs to consume the U-Boot deb
  path.
- **MMC controller index in U-Boot**: which `mmc dev N` enumerates the
  SD card slot is per-board, depending on what the U-Boot DTB declares.
  On `orangepi5` the U-Boot DT exposes only the SD controller and the
  SD card is `mmc 0`; on `orangepi5pro` the U-Boot DT exposes eMMC slot
  + SDIO + SD and the SD card is `mmc 1`. `boot.scr` reads `${devnum}`
  from the bootflow framework so most boots don't care, but anything
  that hard-codes `mmc dev N` (manual U-Boot scripts, recovery aids,
  future per-board hooks) must consult `mmc list` on the actual board.

## Adding a new board (post-v1)

Boards beyond `orange-pi-5-pro` are out of v1 scope. When the next
board comes online:

1. Add a `pre_config_uboot_target__<board>_pxe_first` entry to the
   `build_userpatches` block in `playbooks/build_image.yml`.
2. Add an entry to `vars/boards.yml` with `armbian_dl_dir`,
   `armbian_board_name`, `armbian_support`, `dtb`, `console`.
3. Add the host(s) under a new per-model subgroup of `boards` in
   `inventory/hosts.yml` with `board_mac` and `board_model`.
4. Add an `armbian_image_urls[<board_model>]` entry pointing at the
   locally-published custom build.
5. Run `playbooks/build_image.yml` to produce the image, then
   `stage_netboot_assets.yml` and the rest of the v1 sequence.

## rb5009 SBC TFTP layout

The collection writes file + `/ip tftp` row state on rb5009; no DHCP option-sets,
no lease mutations.

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

Each file has a corresponding `/ip tftp` rule with `req-filename` matching the
path U-Boot requests (e.g. `pxelinux.cfg/01-c0-74-2b-fb-4d-fd`,
`armbian/orange-pi-5-pro/vmlinuz`) and `real-filename` pointing at the flash
path. Per-board state is the file + the row; both are added by `enable_netboot.yml`
and removed (row first) by `disable_netboot.yml`. Per-model assets are added once
by `stage_netboot_assets.yml` and persist across enable/disable cycles.

The SBC subnet's `next-server` (set by your separate RouterOS-config repo) points
at rb5009; combined with U-Boot's PXE bootmeth using `siaddr` for `serverip`, that
sends every TFTP request straight at rb5009.

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

- `vars/boards.yml` — authoritative per-board metadata (v1: orangepi5pro)
- `roles/netboot_assets/tasks/preflight.yml` — image URL HEAD validation
- `roles/netboot_assets/tasks/per_host.yml` — per-host rootfs clone + identity reset
- `roles/netboot_assets/tasks/stage_rb5009.yml` — net_put kernel/initrd/dtb to rb5009
- `roles/netboot_assets/tasks/plumbing_check.yml` — assert /ip tftp rows exist on rb5009
- `roles/routeros_dhcp/tasks/write_pxelinux_cfg.yml` — render locally, net_put per-board pxelinux.cfg to rb5009
- `roles/routeros_dhcp/tasks/remove_pxelinux_cfg.yml` — remove /ip tftp row + flash file
- `inventory/group_vars/all.yml` — IPs, NFS paths, image URLs (edit before first run)
- `roles/routeros_dhcp/templates/pxelinux_cfg.j2` — per-host PXE boot config
- `roles/routeros_poe/tasks/main.yml` — PoE power control (delegates to switch)
- `playbooks/build_image.yml` — custom Armbian image build pipeline
- `galaxy.yml` — collection namespace, version, external dependencies
