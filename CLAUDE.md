# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The `david_igou.armbian_netboot` Ansible collection for managing Armbian-based
ARM SBCs end-to-end. PXE-netboot is a workflow built on the collection's
primitives — it is not the framing.

Every onboarded board always has a pxelinux.cfg on rb5009. The `default`
directive inside it (driven by `armbian_netboot_boot_mode` inventory variable)
selects the active boot mode (nfs or sd). The netboot server (TrueNAS, running
NFS) is assumed to already be running; this collection manages its NFS export
contents, rb5009's SBC TFTP layout, PoE power state, and (via `armbian_build`)
the custom Armbian images those workflows consume.

## Mental model: roles + workflow playbooks

**Roles are single-purpose, parameter-driven state enforcers. Playbooks compose
them into workflows.** A role asks "given these inputs, is the world in the
desired state, and if not, make it so." It does not decide intent; callers do.
A playbook decides which roles to invoke, against which inventory, with which
parameters, in what order.

| Role | Enforces / produces |
|---|---|
| `armbian_build` | `.img.xz` Armbian image with PXE-first U-Boot baked in, published to netboot server |
| `boot_mode` | Board converged to `armbian_netboot_boot_mode: nfs \| sd` (pxelinux.cfg convergence + PoE cycle + rootfs verify) |
| `bootstrap_armbian` | SSH-key user with passwordless sudo on a freshly flashed board |
| `bootstrap_routeros_user` | RouterOS user / group / SSH-key state |
| `netboot_assets` | rootfs / TFTP / pxelinux content under server exports |
| `routeros_pxe_config` | Per-board pxelinux.cfg + `/ip tftp` row on rb5009 (always writes, never removes) |
| `routeros_poe` | PoE port state (on/off) on RouterOS switch ports |

`boot_mode` is the top-level composer for boot-mode convergence: internally it
includes `routeros_pxe_config` (rb5009 mutation, delegated) and `routeros_poe`
(PoE cycle, delegated) and wraps both in a two-layer retry stack. The
`converge_boot_mode.yml` playbook reads `armbian_netboot_boot_mode` from
inventory; `set_boot_mode.yml` accepts it via `-e` for ad-hoc overrides. See
[`docs/boot-mode-override.md`](docs/boot-mode-override.md).

## Status: v2.0.0 — always-netboot model

Breaking change from v1. Every onboarded board always has a pxelinux.cfg on
rb5009 — boot mode is controlled by the `default` directive inside it, not by
file presence/absence. All variables use the `armbian_netboot_` prefix. The
`sd` boot mode requires `armbian_netboot_sd_partuuid` on the host.

Spec: [`docs/superpowers/specs/2026-05-14-always-netboot-migration-design.md`](docs/superpowers/specs/2026-05-14-always-netboot-migration-design.md)

## Collection structure

```
david_igou/armbian_netboot/   (this repo root)
├── galaxy.yml                # Collection metadata (v2.0.0)
├── ansible.cfg               # Ansible config for direct-from-root runs
├── requirements.yml          # External collection dependencies
├── meta/runtime.yml          # Minimum Ansible version (>=2.15)
├── vars/
│   └── boards.yml            # Per-board metadata (armbian_netboot_board_configs)
├── roles/
│   ├── armbian_build/             # Build custom .img.xz on armbian_builders host
│   ├── boot_mode/                 # Converge board to declared mode (pxelinux.cfg + PoE cycle + verify)
│   ├── bootstrap_armbian/         # Provision passwordless-sudo SSH-key user
│   ├── bootstrap_routeros_user/   # Provision RouterOS user/group/SSH keys
│   ├── netboot_assets/            # Populate NFS exports (preflight + per-model + per-host)
│   ├── routeros_pxe_config/       # Per-board pxelinux.cfg + /ip tftp row on RouterOS flash
│   └── routeros_poe/              # PoE power control via RouterOS switch
├── playbooks/
│   ├── bootstrap_armbian.yml        # (0) Provision SSH-key user on flashed boards
│   ├── bootstrap_routeros_user.yml  # (1) Provision RouterOS user/group/SSH keys
│   ├── stage_nfs_rootfs.yml         # (2a) Populate NFS rootfs on TrueNAS
│   ├── stage_tftp_assets.yml        # (2b) Stage per-model kernel/initrd/dtb on rb5009
│   ├── build_image.yml              # Build custom Armbian .img.xz
│   ├── converge_boot_mode.yml       # Converge board(s) to inventory-declared boot mode
│   ├── set_boot_mode.yml            # Set boot mode via -e override (ad-hoc)
│   ├── poe_control.yml              # PoE power on/off/cycle via switch
│   ├── persist_uboot_env.yml        # Approach B: write rock-5b SPI env vars via fw_setenv
│   ├── test_hardware_e2e.yml        # SD → NFS → SD assertion harness
│   └── tasks/
│       └── diagnostic_bundle.yml
├── .inventory/               # Real inventory (gitignored)
├── inventory/                # Documentation-only sample inventory
│   ├── hosts.yml             # orange-pi-5-pro example
│   └── group_vars/
│       ├── all.yml           # Global vars (IPs, paths, image URLs, cross-role defaults)
│       ├── boards.yml        # boot_mode inputs (armbian_netboot_router, retry knobs)
│       └── routeros.yml      # network_cli connection plumbing
└── docs/
    ├── architecture.md
    ├── boot-mode-override.md      # Three override methods (inventory, -e, U-Boot env)
    ├── retry-configuration.md     # Retry/timeout knob tuning recipes
    ├── routeros-setup.md
    └── superpowers/specs/         # Design specs
```

## Running playbooks

Run from the collection root:

```bash
# Install required external collections first
ansible-galaxy collection install -r requirements.yml

# (0) Build the custom Armbian image on a builder host. Publishes the
# resulting .img.xz to the netboot server's HTTP assets directory.
ansible-playbook playbooks/build_image.yml

# (1) Bootstrap a freshly flashed Armbian board: create the inventory's
# `ansible_user` with passwordless sudo + SSH-key auth.
ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01

# (2) Bootstrap the RouterOS SSH user (one-time, against an existing admin user).
ansible-playbook playbooks/bootstrap_routeros_user.yml \
  -e ansible_user=<existing-admin>

# (3a) Stage NFS rootfs on TrueNAS (image extraction + per-host clones).
ansible-playbook playbooks/stage_nfs_rootfs.yml

# (3b) Stage per-model TFTP assets (kernel/initrd/dtb) on rb5009.
ansible-playbook playbooks/stage_tftp_assets.yml

# Converge board(s) to their inventory-declared boot mode.
ansible-playbook playbooks/converge_boot_mode.yml --limit orange-pi-5-pro-01

# Ad-hoc boot mode override (no inventory edit).
ansible-playbook playbooks/set_boot_mode.yml \
  --limit orange-pi-5-pro-01 \
  -e armbian_netboot_boot_mode=sd

# Power cycle a board via its upstream RouterOS switch.
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 \
  -e armbian_netboot_poe_action=cycle

# Persist the U-Boot env vars rock-5b needs for autonomous PXE.
ansible-playbook playbooks/persist_uboot_env.yml --limit rock-5b-01

# Hardware E2E test: converge board through SD → NFS → SD and assert
# each transition. Single board via --limit.
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

`inventory/group_vars/all.yml` — collection-level variables (all `armbian_netboot_*` prefixed):

- `armbian_netboot_server_ip` — IP used as the default fallback for `armbian_netboot_nfs_server_ip`
  when not separately overridden. Written into pxelinux.cfg's `nfsroot=<ip>:<path>` directive.
- `armbian_netboot_tftp_flash_dir` — top-level dir on rb5009's flash for SBC TFTP content.
  Default `sbc`.
- `armbian_netboot_tftp_cache_dir` — control-node cache where kernel/initrd/dtb fetched from
  TrueNAS get stashed before `net_put` to rb5009. Default `{{ playbook_dir }}/../.cache/sbc-tftp/`.
- `armbian_netboot_nfs_server_ip` (optional) — overrides `armbian_netboot_server_ip` for NFS.
- `armbian_netboot_nfs_rootfs_path` — NFS rootfs export root on TrueNAS. Default
  `/mnt/ssd/netboot/rootfs`.
- `armbian_netboot_default_password` — Armbian NFS root SSH password (default `1234`);
  encrypt with vault.
- `armbian_netboot_image_urls` — full `.img.xz` URL per board model.
- `armbian_netboot_nfs_assets_export` — netboot-owned subtree on the HTTP host.
  Default `/mnt/ssd/public/boot-files`.
- **External RouterOS prerequisite**: the SBC subnet's `next-server` must be set to
  rb5009's IP for that subnet. This is owned by your separate RouterOS-config repo
  and not asserted by this collection.

`inventory/group_vars/routeros.yml` only pins the network_cli connection plumbing
(`ansible_connection`, `ansible_network_os`); it intentionally does **not** set
`ansible_user` / `ansible_port` — those are per-host values in `hosts.yml`.

**Three RouterOS groups in `inventory/hosts.yml`**:

- `routeros_routers` — devices that run a DHCP server. `converge_boot_mode.yml`,
  `set_boot_mode.yml`, and `stage_tftp_assets.yml` target this group.
- `routeros_switches` — devices that don't run DHCP but should still get the SSH user.
- `routeros_netboot` — subset that `bootstrap_routeros_user.yml` provisions the
  `ansible-netboot` user on.
- `routeros` (optional parent) — convenience group that includes both; not directly
  targeted by any playbook.

The NFS rootfs export root (`armbian_netboot_nfs_rootfs_path`) must already exist on
the netboot server and be exported. Within it, the role creates `_templates/<model>/`
(per-model rootfs template) and `<inventory_hostname>/` (per-host rootfs clone)
automatically. The control node needs SSH (with `become: true`) to the netboot server,
but does not need an NFS client.

Each board in `inventory/hosts.yml` needs `armbian_netboot_board_mac`,
`armbian_netboot_board_model`, and `armbian_netboot_boot_mode` set. The
`armbian_netboot_board_model` value must exactly match a key in `vars/boards.yml`.

For PoE-powered boards, also set `armbian_netboot_poe_switch` (inventory hostname of
the RouterOS switch providing power) and `armbian_netboot_poe_port` (interface name on
that switch, e.g. `ether3`). These are required by `playbooks/poe_control.yml`.

**`armbian_netboot_router`** (required by the `boot_mode` role, consumed by
`converge_boot_mode.yml` / `set_boot_mode.yml` / `test_hardware_e2e.yml`) — set in
`inventory/group_vars/boards.yml` as `armbian_netboot_router: rb5009`. Identifies the
RouterOS host the role delegates rb5009 mutations to. The role validates this is defined
via `meta/argument_specs.yml` and fails loudly if missing. Run
`ansible-doc -t role david_igou.armbian_netboot.boot_mode` for the full contract.

## Architecture

**The intended invariant**: per-board pxelinux.cfg always exists on rb5009. The
`default` directive inside it selects the active boot mode. U-Boot tries PXE first;
the pxelinux.cfg tells it whether to boot from NFS or fall through to the local SD
card's kernel with a local rootfs PARTUUID.

This invariant is delivered by custom Armbian images built via the `armbian_build`
role — stock Armbian Rockchip `current` ships PXE at position 6 in `BOOT_TARGETS`
and `bootflow scan` lands on mmc1's `boot.scr` first, so a stock image cannot
deliver the invariant. The PXE-first ordering must come from the U-Boot binary's
compile-time `BOOT_TARGETS`, which the `armbian_build` role patches via
`armbian/build`'s `pre_config_uboot_target__<board>_*` hook before U-Boot is
configured.

### Pre-flight validation
`stage_nfs_rootfs.yml` runs `roles/netboot_assets/tasks/preflight.yml` first, which
HEAD-checks every board's `armbian_netboot_image_urls` entry (failing on 4xx/dead mirror)
before any image download or NFS write.

## How netboot content is managed

Two staging playbooks write the server-side state:

`stage_nfs_rootfs.yml` connects to the netboot server (TrueNAS) over SSH
(`hosts: netboot_server`, `become: true`) and operates on
`armbian_netboot_nfs_rootfs_path` + `armbian_netboot_nfs_assets_export` directly as
filesystem paths — no NFS client mount on the control node is required.

`stage_tftp_assets.yml` stages per-model kernel/initrd/dtb to rb5009 by `net_put`-ing
files into `flash:/{{ armbian_netboot_tftp_flash_dir }}/` and registering corresponding
`/ip tftp` rules.

Inside `armbian_netboot_nfs_rootfs_path` two layouts coexist:

```
armbian_netboot_nfs_rootfs_path/
├── _templates/
│   └── orange-pi-5-pro/    per-model template (extracted from .img.xz)
└── orange-pi-5-pro-01/     per-host clone of _templates/orange-pi-5-pro
```

Per-host clones are made with `cp --reflink=auto`, which is a zero-cost CoW snapshot on
XFS, btrfs, and ZFS. Hostname, machine-id, and SSH host keys are reset per-host so two
same-model boards have independent identity on the wire — see
`roles/netboot_assets/tasks/per_host.yml`.

`converge_boot_mode.yml` renders per-board `pxelinux.cfg/01-<mac>` content locally and
`net_put`s it to rb5009's flash, then registers a `/ip tftp` row. The `default` directive
inside the rendered file controls the boot mode. The control node never NFS-mounts
anything and never SSHes to the netboot server during boot-mode convergence — rb5009 is
the entire control surface.

## Where things run

| Playbook | Runs on |
|---|---|
| `bootstrap_armbian.yml` | **boards** (connects as root with `armbian_netboot_default_password`; idempotent) |
| `bootstrap_routeros_user.yml` | RouterOS (router + switches via `routeros_netboot`) |
| `stage_nfs_rootfs.yml` | **netboot server** (image extraction, NFS rootfs) |
| `stage_tftp_assets.yml` | **rb5009** (kernel/initrd/dtb via `net_put` + `/ip tftp` registration) |
| `build_image.yml` | **`armbian_builders`** (Docker-capable build host); publishes to **netboot server** over SSH |
| `converge_boot_mode.yml` / `set_boot_mode.yml` | **rb5009** (pxelinux.cfg convergence) + **boards** (PoE cycle + verify) |
| `poe_control.yml` | **boards** (delegated to `routeros_switches` via `armbian_netboot_poe_switch` hostvar) |
| `persist_uboot_env.yml` | **rock-5b boards** (`fw_setenv` from Linux into SPI) + RouterOS switch (PoE cold-cycle, delegated) |
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

## Adding a new board

For the full runbook, use the `adding-armbian-board` skill — it walks
pre-flight decisions, inventory placeholders, `vars/boards.yml` fields
(including `earlycon`), U-Boot branch selection (`current` vs `edge`
via `build_branches`), post-build defconfig audits (CONFIG_PCI_INIT_R,
PHY drivers, NIC driver presence), and ends at
`stage_nfs_rootfs.yml` + `stage_tftp_assets.yml`. It also encodes the
decision rule for running Approach B (`persist_uboot_env.yml`) based on
whether the board's U-Boot defconfig sets `CONFIG_ENV_IS_IN_SPI_FLASH=y`.

Minimum touched files for a new board:

1. `inventory/hosts.yml` (doc-only example) + your real inventory:
   add the host(s) under a new per-model subgroup of `boards` with
   `armbian_netboot_board_mac`, `armbian_netboot_board_model`,
   `armbian_netboot_boot_mode`, `armbian_netboot_poe_switch`,
   `armbian_netboot_poe_port`.
2. `vars/boards.yml`: entry keyed by `armbian_netboot_board_model` under
   `armbian_netboot_board_configs` with `armbian_dl_dir`,
   `armbian_board_name`, `armbian_support`, `dtb`, `console`, `earlycon`.
3. `inventory/group_vars/all.yml`: add an
   `armbian_netboot_image_urls[<model>]` entry pointing at the
   locally-published custom build.
4. `playbooks/build_image.yml` `build_branches:` if the board's
   family-default U-Boot tree can't netboot (e.g. rk3588 PCIe-NIC
   boards need `edge` for mainline U-Boot).
5. (Rare) `playbooks/build_image.yml` `build_userpatches:` if the
   board needs source patches beyond what `build_userpatches_common`
   already covers — most new boards won't.

## rb5009 SBC TFTP layout

The collection writes file + `/ip tftp` row state on rb5009; no DHCP option-sets,
no lease mutations.

```
flash:/sbc/
├── pxelinux.cfg/
│   └── 01-<MAC>           # per-board (converge_boot_mode.yml writes; always present)
└── armbian/
    └── <model>/
        ├── vmlinuz        # per-model (stage_tftp_assets.yml writes)
        ├── initrd.img
        └── board.dtb
```

Each file has a corresponding `/ip tftp` rule with `req-filename` matching the
path U-Boot requests and `real-filename` pointing at the flash path. Per-board
pxelinux.cfg files always exist — the `default` directive inside selects nfs or
sd boot. Per-model assets are added once by `stage_tftp_assets.yml` and persist
across boot-mode changes.

The SBC subnet's `next-server` (set by your separate RouterOS-config repo) points
at rb5009; combined with U-Boot's PXE bootmeth using `siaddr` for `serverip`, that
sends every TFTP request straight at rb5009.

## PoE power control

`poe_control.yml` targets `boards` with `gather_facts: false` (boards may be powered off)
and delegates the RouterOS command to the switch identified by each board's
`armbian_netboot_poe_switch` host variable. The `delegate_to` pattern works because
`group_vars/routeros.yml` sets `ansible_connection: ansible.netcommon.network_cli` on
all RouterOS hosts, so the delegated task uses the switch's connection settings
automatically.

The role supports three actions via `-e armbian_netboot_poe_action=`:
- `on` — sets `poe-out=auto` (default)
- `off` — sets `poe-out=off`
- `cycle` — off, pause (`armbian_netboot_poe_cycle_delay` seconds, default 5), then on

PoE uses delegation because boards may be connected to different switches. Each board
knows its own switch and port, so delegation routes the command correctly without
filtering.

## Key files

- `vars/boards.yml` — authoritative per-board metadata (`armbian_netboot_board_configs`)
- `roles/boot_mode/meta/argument_specs.yml` — boot_mode role contract (validated at include time)
- `roles/boot_mode/tasks/main.yml` — boot_mode dispatcher (converge → cycle → verify)
- `roles/boot_mode/tasks/cold_boot_with_retry.yml` — layer-1 retry primitive (PoE cycle + TCP/22 + ssh-ping)
- `roles/boot_mode/tasks/wait_for_ssh_with_cycle_retry.yml` — layer-2 retry primitive (post-boot SSH wait + cycle retry)
- `roles/netboot_assets/tasks/preflight.yml` — image URL HEAD validation
- `roles/netboot_assets/tasks/per_host.yml` — per-host rootfs clone + identity reset
- `roles/netboot_assets/tasks/stage_rb5009.yml` — net_put kernel/initrd/dtb to rb5009
- `roles/netboot_assets/tasks/plumbing_check.yml` — assert /ip tftp rows exist on rb5009
- `roles/routeros_pxe_config/tasks/main.yml` — render locally, net_put per-board pxelinux.cfg to rb5009
- `roles/routeros_pxe_config/templates/pxelinux_cfg.j2` — per-host PXE boot config (multi-label, default-driven)
- `inventory/group_vars/all.yml` — IPs, NFS paths, image URLs, cross-role defaults (edit before first run)
- `inventory/group_vars/boards.yml` — `armbian_netboot_router` and boot_mode retry-knob overrides
- `roles/routeros_poe/tasks/main.yml` — PoE power control (delegates to switch)
- `playbooks/build_image.yml` — custom Armbian image build pipeline
- `playbooks/persist_uboot_env.yml` — Approach B for rock-5b autonomous PXE
- `docs/boot-mode-override.md` — three boot mode override methods (inventory, -e, U-Boot env)
- `docs/retry-configuration.md` — retry/timeout knob recipes
- `docs/uboot-armbian-build-explainer.html` — §8 "Fixing rock-5b's autonomous-PXE problem"
- `galaxy.yml` — collection namespace, version (2.0.0), external dependencies
