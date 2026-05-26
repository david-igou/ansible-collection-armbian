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
contents, rb5009's SBC TFTP layout, PoE power state, and (via `image_build`)
the custom Armbian images those workflows consume.

## Mental model: roles + workflow playbooks

**Roles are single-purpose, parameter-driven state enforcers. Playbooks compose
them into workflows.** A role asks "given these inputs, is the world in the
desired state, and if not, make it so." It does not decide intent; callers do.
A playbook decides which roles to invoke, against which inventory, with which
parameters, in what order.

| Role | Runs on | Enforces / produces |
|---|---|---|
| `image_build` | `armbian_builders` | `.img.xz` with PXE-first U-Boot baked in; optional SCP publish gated by `armbian_netboot_publish_target` |
| `image_extract` | netboot server (host with sudo+losetup) | One rootfs template + per-model TFTP artifacts (vmlinuz/initrd/board.dtb) from a `.img.xz` (local path or URL) |
| `disk_image` | a board (or any host owning the target) | One block device imaged via streaming `xz \| dd`; mount-aware refusal |
| `rootfs_clone` | netboot server | Per-host rootfs clone (reflink-copy of a template) with identity reset |
| `pxelinux_render` | `localhost` (via `delegate_to`) | One `01-<mac>` pxelinux.cfg file in a local directory |
| `board_boot_wait` | a board | wait_for TCP/22 + SSH (no power knowledge) |
| `board_boot_verify` | a board | Asserts `ansible_mounts['/']` matches declared boot mode |
| `bootstrap_armbian` | a board | SSH-key user with passwordless sudo on a freshly flashed board |

Roles are transport-agnostic. Networking-gear-specific tasks (RouterOS upload,
PoE control, user provisioning) live as reference playbooks under
`playbooks/routeros/`; a user swapping switch ecosystems writes a parallel
directory and points the transport-hook variables at it. Top-level orchestration
playbooks (`converge_boot_mode.yml`, `stage_router.yml`, `test_hardware_e2e.yml`)
compose roles + reference playbooks. See
[`docs/boot-mode-override.md`](docs/boot-mode-override.md).

## Status: v3.0.0 — single-purpose, transport-agnostic roles

Breaking change from v2. The five composite v2 roles (`boot_mode`,
`netboot_assets`, `routeros_pxe_config`, `routeros_poe`,
`bootstrap_routeros_user`) are gone. v3 ships seven single-host, single-purpose
roles with zero RouterOS knowledge; all RouterOS-specific code lives as
swappable reference playbooks under `playbooks/routeros/`. Inventory variables,
boot-mode semantics, and CLI entry points are preserved.

The always-netboot model from v2 carries forward unchanged: every onboarded
board always has a pxelinux.cfg on rb5009, boot mode is controlled by the
`default` directive inside it, and the `sd` label defaults to
`root=LABEL=armbi_root` (override per-host via `armbian_netboot_sd_root`).

Specs:
- v3: [`docs/superpowers/specs/2026-05-16-role-refactor-v3-design.md`](docs/superpowers/specs/2026-05-16-role-refactor-v3-design.md)
- v2 (boot-mode model): [`docs/superpowers/specs/2026-05-14-always-netboot-migration-design.md`](docs/superpowers/specs/2026-05-14-always-netboot-migration-design.md)

## Collection structure

```
david_igou/armbian_netboot/   (this repo root)
├── galaxy.yml                # Collection metadata (v3.0.0)
├── ansible.cfg               # Ansible config for direct-from-root runs
├── requirements.yml          # Runtime deps (roles/ only — ansible.posix)
├── meta/runtime.yml          # Minimum Ansible version (>=2.15)
├── vars/
│   └── boards.yml            # Per-board metadata (armbian_netboot_board_configs)
├── roles/                    # All single-host, single-purpose, transport-agnostic
│   ├── image_build/               # Build custom .img.xz on armbian_builders host
│   ├── image_extract/             # Extract one .img.xz → template rootfs + TFTP files
│   ├── disk_image/                # Stream an .img.xz/.img to a block device (dd-style)
│   ├── rootfs_clone/              # Reflink-clone a template into a per-host rootfs
│   ├── pxelinux_render/           # Render one per-board pxelinux.cfg to a local dir
│   ├── board_boot_wait/           # Wait for TCP/22 + SSH on a board
│   ├── board_boot_verify/         # Assert rootfs matches declared boot mode
│   └── bootstrap_armbian/         # Provision passwordless-sudo SSH-key user
├── playbooks/
│   ├── bootstrap_armbian.yml        # Provision SSH-key user on flashed boards
│   ├── stage_netboot_assets.yml     # Extract templates + clone per-host rootfs on netboot server
│   ├── stage_router.yml             # Fetch TFTP cache to controller → push to router + verify rows
│   ├── build_image.yml              # Build custom Armbian .img.xz
│   ├── converge_boot_mode.yml       # Converge board(s) to inventory-declared boot mode
│   ├── set_boot_mode.yml            # Thin wrapper around converge for -e override
│   ├── poe_control.yml              # PoE on/off/cycle (wraps routeros/poe_control.yml)
│   ├── persist_uboot_env.yml        # Approach B: write rock-5b SPI env vars via fw_setenv
│   ├── test_hardware_e2e.yml        # SD → NFS → SD assertion harness
│   ├── routeros/                    # RouterOS-specific reference playbooks (swappable)
│   │   ├── requirements.yml           # Optional deps: community.routeros + ansible.netcommon
│   │   ├── bootstrap_user.yml         # Provision ansible-netboot user/group/SSH keys
│   │   ├── upload_pxelinux_cfg.yml    # Per-board pxelinux.cfg upload + /ip tftp rows
│   │   ├── upload_tftp_assets.yml     # Per-model kernel/initrd/dtb upload + rows
│   │   ├── plumbing_check.yml         # Assert /ip tftp rows exist for given models
│   │   ├── poe_control.yml            # PoE on/off/cycle on a board's switch port
│   │   └── tasks/
│   │       ├── upload_file.yml        # Shared primitive: net_put + /ip tftp row
│   │       ├── poe_cycle.yml          # Shared primitive: off → drain → on
│   │       └── upload_pxelinux_one.yml # Per-host pxelinux upload (for in-play use)
│   ├── tests/
│   │   └── test_build_image_vars.yml   # Localhost inventory-contract test for build_image.yml's per-model vars
│   └── tasks/
│       ├── cold_boot_with_retry.yml      # PoE cycle + wait_for TCP/22 with retries
│       ├── cold_boot_single_attempt.yml  # Inner block/rescue for one attempt
│       ├── wait_for_ssh_with_cycle_retry.yml # Post-boot wait with cycle retry
│       ├── auto_bootstrap_if_needed.yml  # SSH probe → bootstrap_armbian fallback
│       ├── render_and_upload_pxelinux.yml # Render locally + upload to router (e2e/manual-PSU helper)
│       └── diagnostic_bundle.yml         # findmnt/cmdline/journal capture on failure
├── .inventory/               # Real inventory (gitignored)
├── inventory/                # Documentation-only sample inventory
│   ├── hosts.yml             # orange-pi-5-pro example
│   └── group_vars/
│       ├── all.yml           # Global vars (IPs, paths, image URLs, cross-role defaults)
│       ├── boards.yml        # netboot inputs (armbian_netboot_router, retry knobs)
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
# Install runtime collection dependencies (roles/ only).
ansible-galaxy collection install -r requirements.yml
# If you use any orchestration that talks to RouterOS (stage_router.yml,
# converge_boot_mode.yml, poe_control.yml, the routeros/ reference
# playbooks, or the test_*_e2e.yml harnesses), also install:
ansible-galaxy collection install -r playbooks/routeros/requirements.yml

# (0) Build the custom Armbian image on a builder host. Publishes the
# resulting .img.xz to the netboot server's HTTP assets directory.
ansible-playbook playbooks/build_image.yml

# (1) Bootstrap a freshly flashed Armbian board: create the inventory's
# `ansible_user` with passwordless sudo + SSH-key auth.
ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01

# (2) Bootstrap the RouterOS SSH user (one-time, against an existing admin user).
ansible-playbook playbooks/routeros/bootstrap_user.yml \
  -e ansible_user=<existing-admin>

# (3a) Stage netboot assets on the netboot server (image extraction + per-host clones).
ansible-playbook playbooks/stage_netboot_assets.yml

# (3b) Stage per-model TFTP assets on the router (fetch to controller + push + verify rows).
ansible-playbook playbooks/stage_router.yml

# Converge board(s) to their inventory-declared boot mode.
ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01

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
- `armbian_netboot_image_urls` — per-model `.img.xz` source consumed by
  `image_extract` on the netboot_server (Phase 1 of `test_fleet_e2e.yml`,
  plus `stage_netboot_assets.yml`). Typically a local NFS path on the
  server.
- `armbian_netboot_image_urls_http` — per-model http(s):// URL consumed
  by the `disk_image` role on each board (Phase 3 of `test_fleet_e2e.yml`).
  Must resolve to the SAME `.img.xz` as `armbian_netboot_image_urls` but
  via a URL the boards can reach (the netboot_server often can't reach
  its own macvlan-fronted HTTP address, hence the split).
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
  `set_boot_mode.yml`, and `stage_router.yml` target this group.
- `routeros_switches` — devices that don't run DHCP but should still get the SSH user.
- `routeros_netboot` — subset that `playbooks/routeros/bootstrap_user.yml`
  provisions the `ansible-netboot` user on.
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

**`armbian_netboot_router`** (consumed by `converge_boot_mode.yml`,
`set_boot_mode.yml`, `stage_router.yml`, `test_hardware_e2e.yml`, and
`persist_uboot_env.yml` for router-side delegation) — set in
`inventory/group_vars/boards.yml` as `armbian_netboot_router: rb5009`.
Identifies the inventory host the playbooks delegate router mutations to.

## Architecture

**The intended invariant**: per-board pxelinux.cfg always exists on rb5009. The
`default` directive inside it selects the active boot mode. U-Boot tries PXE first;
the pxelinux.cfg tells it whether to boot from NFS or fall through to the local SD
card's kernel with a local rootfs PARTUUID.

This invariant is delivered by custom Armbian images built via the `image_build`
role — stock Armbian Rockchip `current` ships PXE at position 6 in `BOOT_TARGETS`
and `bootflow scan` lands on mmc1's `boot.scr` first, so a stock image cannot
deliver the invariant. The PXE-first ordering must come from the U-Boot binary's
compile-time `BOOT_TARGETS`, which the `image_build` role patches via
`armbian/build`'s `pre_config_uboot_target__<board>_*` hook before U-Boot is
configured.

## How netboot content is managed

Two staging playbooks write the server-side state:

`stage_netboot_assets.yml` connects to the netboot server (TrueNAS) over SSH
(`hosts: netboot_server`, `become: true`) and composes the `image_extract` +
`rootfs_clone` roles. `image_extract` accepts a `.img.xz` source as either a
local path on the server or an `http(s)://` URL, so the playbook works whether
images are pre-published locally or fetched on demand.

`stage_router.yml` is a 3-play composition: play 1 fetches the per-model
kernel/initrd/dtb from `netboot_server` to the controller cache; play 2
imports the transport-specific upload playbook (defaults to
`routeros/upload_tftp_assets.yml`); play 3 imports the plumbing-check
reference to verify rows landed.

Inside `armbian_netboot_nfs_rootfs_path` two layouts coexist:

```
armbian_netboot_nfs_rootfs_path/
├── _templates/
│   └── orange-pi-5-pro/    per-model template (extracted from .img.xz)
└── orange-pi-5-pro-01/     per-host clone of _templates/orange-pi-5-pro
```

Per-host clones are made with `cp --reflink=auto`, which is a zero-cost CoW
snapshot on XFS, btrfs, and ZFS. Hostname, machine-id, and SSH host keys are
reset per-host so two same-model boards have independent identity on the wire —
see `roles/rootfs_clone/tasks/_identity_reset.yml`.

`converge_boot_mode.yml` is a four-play composition: pre-flight plumbing
check (router), local pxelinux render (boards, delegated to localhost),
upload reference playbook (router, swappable transport), and cycle+wait+verify
on boards. The control node never NFS-mounts anything and never SSHes to the
netboot server during boot-mode convergence.

## Where things run

| Playbook | Runs on |
|---|---|
| `bootstrap_armbian.yml` | **boards** (connects as root with `armbian_netboot_default_password`; idempotent) |
| `routeros/bootstrap_user.yml` | RouterOS (router + switches via `routeros_netboot`) |
| `stage_netboot_assets.yml` | **netboot server** (image extraction, NFS rootfs, per-host clones) |
| `stage_router.yml` | **netboot server** (fetch to controller) + **rb5009** (net_put + /ip tftp registration + plumbing check) |
| `build_image.yml` | **`armbian_builders`** (Docker-capable build host); publishes to **netboot server** over SSH |
| `converge_boot_mode.yml` / `set_boot_mode.yml` | **rb5009** (plumbing check + pxelinux upload) + **boards** (pxelinux render via delegate localhost, PoE cycle + wait + verify) |
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
- **Ethernet controller / PHY chip**: per-SKU *and* per-revision. The
  same board name from the same vendor can ship with different ethernet
  silicon across production runs — e.g. early Orange Pi 5 batches used
  RTL8211F, later batches use Motorcomm YT8531C, and Orange Pi 5 Pro
  switched to a Motorcomm YT6801 PCIe NIC entirely (with `&gmac1
  { status = "disabled"; }` in the upstream u-boot DT). Vendor product
  pages routinely lag the actual BOM. Implications: U-Boot needs the
  Kconfig PHY driver matching the *actual* OUI the PHY reports — a
  mismatch silently looks like "PXE doesn't work" with no log to point
  at it. **Always confirm the live chip via Linux** before patching
  U-Boot configs:
  ```bash
  ethtool -i end0                 # bus + driver name
  dmesg | grep -iE 'phy|gmac|stmmac|mdio'  # PHY OUI bind line
  lspci -nn | grep -i ethernet    # for PCIe-NIC boards
  ```
  The kernel's MDIO probe reads PHY ID registers and binds the right
  driver regardless of what U-Boot has — so kernel output is the
  ground truth for what's actually on the board.

## Adding a new board

For the full runbook, use the `adding-armbian-board` skill — it walks
pre-flight decisions, inventory placeholders, `vars/boards.yml` fields
(including `earlycon`), U-Boot branch selection (`current` vs `edge`
via `armbian_netboot_board_branch` in inventory group_vars), post-build defconfig audits (CONFIG_PCI_INIT_R,
PHY drivers, NIC driver presence), and ends at
`stage_netboot_assets.yml` + `stage_router.yml`. It also encodes the
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
   locally-published custom build (consumed on the netboot_server),
   AND an `armbian_netboot_image_urls_http[<model>]` entry with the
   http(s):// URL the boards stream from for the Phase 3 dd-to-SD step.
4. `inventory/group_vars/<model_group>.yml` (doc-only example +
   real inventory): set `armbian_netboot_board_branch` if the board's
   family-default U-Boot tree can't netboot (e.g. rk3588 PCIe-NIC
   boards need `edge` for mainline U-Boot). Default `current` if
   omitted.
5. (Rare) `inventory/group_vars/<model_group>.yml`
   `armbian_netboot_board_userpatches`: list of `{dest, content}`
   patches the image_build role drops into `userpatches/` for this
   board's build. Add only after confirming `build_userpatches_common`
   in `playbooks/build_image.yml` (the cross-board rk3588 family
   overlay) doesn't already cover the case.

## rb5009 SBC TFTP layout

The collection writes file + `/ip tftp` row state on rb5009; no DHCP option-sets,
no lease mutations.

```
flash:/sbc/
├── pxelinux.cfg/
│   └── 01-<MAC>           # per-board (converge_boot_mode.yml writes; always present)
└── armbian/
    └── <model>/
        ├── vmlinuz        # per-model (stage_router.yml writes)
        ├── initrd.img
        └── board.dtb
```

Each file has a corresponding `/ip tftp` rule with `req-filename` matching the
path U-Boot requests and `real-filename` pointing at the flash path. Per-board
pxelinux.cfg files always exist — the `default` directive inside selects nfs or
sd boot. Per-model assets are added once by `stage_router.yml` and persist
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
- `roles/image_extract/tasks/main.yml` — single-image extraction (URL or local path) → template + TFTP files
- `roles/disk_image/tasks/main.yml` — orchestrate validate → write → settle for the new disk-imaging role
- `roles/disk_image/tasks/_validate.yml` — mount-aware guard + extension classify (pre-flight)
- `roles/disk_image/tasks/_write.yml` — four-branch streaming write with pipefail propagation
- `roles/rootfs_clone/tasks/main.yml` — reflink-clone template into per-host rootfs + identity reset
- `roles/pxelinux_render/tasks/main.yml` — render one per-board pxelinux.cfg locally
- `roles/pxelinux_render/templates/pxelinux_cfg.j2` — multi-label, default-driven PXE config
- `roles/board_boot_wait/tasks/main.yml` — TCP/22 + SSH wait on a board (no power knowledge)
- `roles/board_boot_verify/tasks/main.yml` — assert rootfs fstype matches declared boot mode
- `playbooks/tasks/cold_boot_with_retry.yml` — outer retry loop (PoE cycle + TCP/22 + ssh-ping)
- `playbooks/tasks/cold_boot_single_attempt.yml` — inner block/rescue for one attempt
- `playbooks/tasks/wait_for_ssh_with_cycle_retry.yml` — post-boot SSH wait with cycle retry
- `playbooks/tasks/auto_bootstrap_if_needed.yml` — SSH probe + bootstrap_armbian fallback
- `playbooks/tasks/render_and_upload_pxelinux.yml` — combined render+upload helper for in-play use
- `playbooks/routeros/upload_pxelinux_cfg.yml` — per-board pxelinux.cfg upload + /ip tftp rows
- `playbooks/routeros/upload_tftp_assets.yml` — per-model kernel/initrd/dtb upload + rows
- `playbooks/routeros/plumbing_check.yml` — assert /ip tftp rows exist on router
- `playbooks/routeros/poe_control.yml` — PoE on/off/cycle delegated to a board's switch
- `playbooks/routeros/bootstrap_user.yml` — provision ansible-netboot user/group/SSH keys
- `inventory/group_vars/all.yml` — IPs, NFS paths, image URLs, cross-role defaults (edit before first run)
- `inventory/group_vars/boards.yml` — `armbian_netboot_router` + retry-knob overrides
- `playbooks/build_image.yml` — custom Armbian image build pipeline
- `playbooks/persist_uboot_env.yml` — Approach B for rock-5b autonomous PXE
- `docs/boot-mode-override.md` — three boot mode override methods (inventory, -e, U-Boot env)
- `docs/retry-configuration.md` — retry/timeout knob recipes
- `docs/uboot-armbian-build-explainer.html` — §8 "Fixing rock-5b's autonomous-PXE problem"
- `galaxy.yml` — collection namespace, version (3.0.0), external dependencies
