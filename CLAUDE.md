# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The `david_igou.armbian` Ansible collection for managing Armbian-based
ARM SBCs end-to-end. PXE-netboot is a workflow built on the collection's
primitives — it is not the framing.

Every onboarded board always has a pxelinux.cfg on rb5009. The `default`
directive inside it (driven by `armbian_boot_mode` inventory variable)
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
| `image_build` | `armbian_builders` | `.img.xz` with PXE-first U-Boot baked in; staged to controller (companion `build_and_publish_from_inventory.yml` publishes to the netboot server) |
| `rootfs_provision` | netboot server (host with sudo+losetup) | Per-host NFS rootfs: extracts `.img.xz` (local path or URL) into a per-model template, reflink-clones it to a per-host directory, and resets identity (hostname/machine-id/SSH host keys) |
| `disk_image` | a board (or any host owning the target) | One block device imaged via streaming `xz \| dd`; mount-aware refusal |
| `disk_provision` | a board | Declarative GPT layout via `systemd-repart` + rsync source rootfs + LABEL-keyed fstab regen; idempotent, supports `preserve_on_reprovision` per partition |
| `pxelinux_render` | `localhost` (via `delegate_to`) | One `01-<mac>` pxelinux.cfg file in a local directory |
| `board_boot_wait` | a board | wait_for TCP/22 + SSH (no power knowledge) |
| `board_boot_verify` | a board | Asserts `ansible_mounts['/']` matches declared boot mode |
| `bootstrap_armbian` | a board | SSH-key user with passwordless sudo on a freshly flashed board |

Roles are transport-agnostic. Networking-gear-specific tasks (RouterOS upload,
PoE control, user provisioning) live as reference playbooks under
`playbooks/routeros/`; a user swapping switch ecosystems writes a parallel
directory and points the transport-hook variables at it. Top-level orchestration
playbooks (`converge_boot_mode.yml`, `stage_router.yml`) and the E2E harnesses
under `playbooks/tests/` (`test_hardware_e2e.yml`) compose roles + reference
playbooks. See
[`docs/boot-mode-override.md`](docs/boot-mode-override.md).

## Status: early-stage (0.0.x) — expect breaking changes

Roles are single-purpose, single-host, and transport-agnostic; all
RouterOS-specific code lives as swappable reference playbooks under
`playbooks/routeros/`. The collection is in active development with
breaking changes between releases — inventory variables, default
values, group names, role names, and playbook names may all shift
between 0.0.x releases without long deprecation windows. Pin to a
specific version in your `requirements.yml`.

The always-netboot model: every onboarded board always has a
pxelinux.cfg on the RouterOS router, boot mode is controlled by the
`default` directive inside it, and the `sd` label defaults to
`root=LABEL=armbi_root` (override per-host via `armbian_sd_root`).

## Collection structure

```
david_igou/armbian/   (this repo root)
├── galaxy.yml                # Collection metadata
├── ansible.cfg               # Ansible config for direct-from-root runs
├── requirements.yml          # Runtime deps (roles/ only — ansible.posix)
├── meta/runtime.yml          # Minimum Ansible version (>=2.15)
├── roles/                    # All single-host, single-purpose, transport-agnostic
│   ├── image_build/               # Build custom .img.xz on armbian_builders host
│   ├── rootfs_provision/          # Extract .img.xz → per-model template + per-host clone + identity reset
│   ├── disk_image/                # Stream an .img.xz/.img to a block device (dd-style)
│   ├── disk_provision/            # Declarative GPT layout via systemd-repart + rsync + LABEL-keyed fstab
│   ├── pxelinux_render/           # Render one per-board pxelinux.cfg to a local dir
│   ├── board_boot_wait/           # Wait for TCP/22 + SSH on a board
│   ├── board_boot_verify/         # Assert rootfs matches declared boot mode
│   └── bootstrap_armbian/         # Provision passwordless-sudo SSH-key user
├── playbooks/
│   ├── bootstrap_armbian.yml        # Provision SSH-key user on flashed boards
│   ├── stage_netboot_assets.yml     # Per-host rootfs_provision on netboot server (extract + clone)
│   ├── stage_router.yml             # Fetch TFTP cache to controller → push to router + verify rows
│   ├── build_and_publish_from_inventory.yml  # Build custom Armbian .img.xz + publish to netboot server
│   ├── cleanup_boot_files.yml       # Remove stale per-host pxelinux.cfg + per-model TFTP rows
│   ├── converge_boot_mode.yml       # Converge board(s) to inventory-declared boot mode
│   ├── set_boot_mode.yml            # Thin wrapper around converge for -e override
│   ├── poe_control.yml              # PoE on/off/cycle (wraps routeros/poe_control.yml)
│   ├── persist_uboot_env.yml        # Write SPI U-Boot env vars via fw_setenv (rock-5b etc.)
│   ├── provision_local_disk.yml     # Compose disk_provision against a board's local disk
│   ├── reprovision_to_local.yml     # Headless NFS-boot → reprovision → flip pxelinux to local
│   ├── examples/                    # Per-role demo playbooks (one role each; known-good usage)
│   │   ├── image_build.yml            # Demo: build one .img.xz via the image_build role
│   │   ├── rootfs_provision.yml       # Demo: per-host NFS rootfs via the rootfs_provision role
│   │   ├── disk_image.yml             # Demo: stream an .img.xz onto a block device
│   │   ├── disk_provision.yml         # Demo: declarative GPT layout + rsync via disk_provision
│   │   ├── pxelinux_render.yml        # Demo: render one per-board pxelinux.cfg locally
│   │   ├── board_boot_wait.yml        # Demo: TCP/22 + SSH wait via board_boot_wait
│   │   └── board_boot_verify.yml      # Demo: assert rootfs matches declared boot mode
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
│   ├── tests/                       # Hardware E2E harnesses + localhost var-contract tests
│   │   ├── test_fleet_e2e.yml          # Deterministic six-phase whole-fleet harness
│   │   ├── test_hardware_e2e.yml       # SD → NFS → SD single-board assertion harness
│   │   ├── test_manual_psu_cold_boot.yml # NFS converge for USB-C powered boards (manual power)
│   │   ├── test_reprovision_e2e.yml    # Single-board reprovision regression
│   │   ├── test_build_and_publish_vars.yml   # Localhost inventory-contract test for build_and_publish_from_inventory.yml's per-host resolver contract
│   │   ├── test_resolve_board_config.yml     # Localhost test for tasks/_resolve_board_config.yml
│   │   ├── test_resolve_build_profile.yml    # Localhost test for tasks/_resolve_build_profile.yml
│   │   └── test_resolve_rootfs_src.yml       # Localhost test for tasks/_resolve_rootfs_src.yml
│   └── tasks/
│       ├── _converge_boot_mode.yml         # Inner converge primitive used by lifecycle wrappers
│       ├── _lifecycle_set_and_verify.yml   # Converge + verify with diagnostic-bundle on failure
│       ├── _resolve_board_config.yml       # Merge family/model/host layers → armbian_board_config fact
│       ├── _resolve_build_profile.yml      # Merge family/model/host build layers → armbian_build fact
│       ├── _resolve_rootfs_src.yml         # Derive per-host armbian_rootfs_src from host_vars or published manifest
│       ├── auto_bootstrap_if_needed.yml    # SSH probe → bootstrap_armbian fallback
│       ├── cold_boot_single_attempt.yml    # Inner block/rescue for one cold-boot attempt
│       ├── cold_boot_with_retry.yml        # PoE cycle + wait_for TCP/22 with retries
│       ├── compose_uboot_env_vars.yml      # Build the converged U-Boot env dict
│       ├── diagnostic_bundle.yml           # findmnt/cmdline/journal capture on failure
│       ├── render_and_upload_pxelinux.yml  # Render locally + upload to router (e2e/manual-PSU helper)
│       ├── validate_local_kernel.yml       # Assert local_kernel preconditions per host
│       └── wait_for_ssh_with_cycle_retry.yml # Post-boot wait with cycle retry
├── .inventory/               # Real inventory (gitignored)
├── inventory/                # Documentation-only sample inventory
│   ├── hosts.yml             # orange-pi-5-pro example
│   └── group_vars/
│       ├── all.yml                # Global vars (IPs, paths, cross-role defaults)
│       ├── armbian.yml            # Parent group vars for armbian_builders + boards (family hooks now live in <family>.yml)
│       ├── boards.yml             # netboot inputs (armbian_router, retry knobs)
│       ├── <family>.yml           # Per-SoC-family vars: armbian_board_config_family, armbian_build_family
│       ├── <model_group>.yml      # Per-model vars: armbian_board_config_model, armbian_build_model
│       └── routeros.yml           # network_cli connection plumbing
└── docs/
    ├── boot-mode-override.md      # Three override methods (inventory, -e, U-Boot env)
    ├── retry-configuration.md     # Retry/timeout knob tuning recipes
    └── runbooks/
        └── reprovision-local-disk.md  # disk_provision lifecycle runbook
```

**`playbooks/` layout convention** — three buckets, sorted by purpose:

- **Top level** = workflow playbooks you actually run in operation (the
  "verbs"). These are the only ones addressable by FQCN
  (`david_igou.armbian.<name>`).
- **`examples/`** = one demo playbook per role, showing the minimal
  known-good role call. Run by path; not for production use.
- **`tests/`** = hardware E2E harnesses + localhost var-contract tests.

A new playbook belongs in whichever bucket matches its purpose; keep the
top level limited to operational workflows.

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
ansible-playbook playbooks/build_and_publish_from_inventory.yml

# (1) Bootstrap a freshly flashed Armbian board: create the inventory's
# `ansible_user` with passwordless sudo + SSH-key auth.
ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01

# (2) Bootstrap the RouterOS SSH user (one-time, against an existing admin user).
ansible-playbook playbooks/routeros/bootstrap_user.yml \
  -e ansible_user=<existing-admin>

# (3a) Stage netboot assets on the netboot server (per-host rootfs_provision).
ansible-playbook playbooks/stage_netboot_assets.yml

# (3b) Stage per-model TFTP assets on the router (fetch to controller + push + verify rows).
ansible-playbook playbooks/stage_router.yml

# Converge board(s) to their inventory-declared boot mode.
ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01

# Ad-hoc boot mode override (no inventory edit).
ansible-playbook playbooks/set_boot_mode.yml \
  --limit orange-pi-5-pro-01 \
  -e armbian_boot_mode=sd

# Power cycle a board via its upstream RouterOS switch.
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 \
  -e armbian_poe_action=cycle

# Persist the U-Boot env vars SPI-flash boards need for autonomous PXE.
ansible-playbook playbooks/persist_uboot_env.yml --limit rock-5b-01

# Reprovision a board's local disk(s) via systemd-repart + rsync.
# Composes the disk_provision role; refuses to wipe the disk the board
# is currently booted from.
ansible-playbook playbooks/provision_local_disk.yml --limit orange-pi-5-pro-01

# Headless full-lifecycle reprovision: boot NFS → reprovision local
# disk(s) → flip pxelinux to local → verify (auto-reverts on failure).
ansible-playbook playbooks/reprovision_to_local.yml --limit orange-pi-5-pro-01

# Clean up stale TFTP rows + per-host pxelinux.cfg for retired boards.
ansible-playbook playbooks/cleanup_boot_files.yml

# Hardware E2E test: converge a single board through SD → NFS → SD and
# assert each transition. Single board via --limit.
ansible-playbook playbooks/tests/test_hardware_e2e.yml --limit orange-pi-5-pro-01

# Deterministic whole-fleet E2E test: six phases × all target boards.
# See `.claude/skills/running-fleet-e2e-test/` for the wrapper.
ansible-playbook playbooks/tests/test_fleet_e2e.yml

# Single-board reprovision regression test.
ansible-playbook playbooks/tests/test_reprovision_e2e.yml --limit orange-pi-5-pro-01
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

`inventory/group_vars/all.yml` — collection-level variables (all `armbian_*` prefixed):

- `armbian_server_ip` — IP used as the default fallback for `armbian_nfs_server_ip`
  when not separately overridden. Written into pxelinux.cfg's `nfsroot=<ip>:<path>` directive.
- `armbian_tftp_flash_dir` — top-level dir on rb5009's flash for SBC TFTP content.
  Default `sbc`.
- `armbian_tftp_cache_dir` — control-node cache where kernel/initrd/dtb fetched from
  TrueNAS get stashed before `net_put` to rb5009. Default `{{ playbook_dir }}/../.cache/sbc-tftp/`.
- `armbian_nfs_server_ip` (optional) — overrides `armbian_server_ip` for NFS.
- `armbian_nfs_rootfs_path` — NFS rootfs export root on TrueNAS. Default
  `/srv/netboot/rootfs`.
- `armbian_default_password` — Armbian NFS root SSH password (default `1234`);
  encrypt with vault.
- `armbian_rootfs_src` — per-host `.img.xz` source (optional). When set
  on a host (in `host_vars` or `group_vars/<model_group>.yml`), it
  overrides the published-manifest lookup for both `rootfs_provision` on
  the netboot_server and `disk_image` on each board. Each value is an
  `https://` URL, `http://` URL, or absolute path; whichever you set must
  be reachable from both the netboot_server and the boards. When omitted,
  `_resolve_rootfs_src.yml` derives the URL from the published manifest on
  the netboot server (requires `build_and_publish_from_inventory.yml` to
  have run at least once).
- `armbian_nfs_assets_export` — netboot-owned subtree on the HTTP host.
  Default `/srv/netboot/boot-files`.
- **External RouterOS prerequisite**: the SBC subnet's `next-server` must be set to
  rb5009's IP for that subnet. This is owned by your separate RouterOS-config repo
  and not asserted by this collection.

`inventory/group_vars/routeros.yml` only pins the network_cli connection plumbing
(`ansible_connection`, `ansible_network_os`); it intentionally does **not** set
`ansible_user` / `ansible_port` — those are per-host values in `hosts.yml`.

**Three RouterOS groups in `inventory/hosts.yml`**:

- `routeros_router` — devices that run a DHCP server. `converge_boot_mode.yml`,
  `set_boot_mode.yml`, and `stage_router.yml` target this group.
- `routeros_switch` — devices that don't run DHCP but should still get the SSH user.
- `routeros_netboot` — subset that `playbooks/routeros/bootstrap_user.yml`
  provisions the `ansible-netboot` user on.
- `routeros` (optional parent) — convenience group that includes both; not directly
  targeted by any playbook.

The NFS rootfs export root (`armbian_nfs_rootfs_path`) must already exist on
the netboot server and be exported. Within it, the role creates `_templates/<model>/`
(per-model rootfs template) and `<inventory_hostname>/` (per-host rootfs clone)
automatically. The control node needs SSH (with `become: true`) to the netboot server,
but does not need an NFS client.

Each board in `inventory/hosts.yml` needs `armbian_board_mac`,
`armbian_board_model`, and `armbian_boot_mode` set. The
`armbian_board_model` value is consumed by `_resolve_board_config.yml`
to merge the `armbian_board_config_family`, `armbian_board_config_model`,
and optional `armbian_board_config_host` inventory layers into a resolved
`armbian_board_config` fact. Board metadata (dtb, console, earlycon, etc.)
lives in `inventory/group_vars/<model_group>.yml` rather than in the
collection's `vars/` tree.

For PoE-powered boards, also set `armbian_poe_switch` (inventory hostname of
the RouterOS switch providing power) and `armbian_poe_port` (interface name on
that switch, e.g. `ether3`). These are required by `playbooks/poe_control.yml`.

**`armbian_router`** (consumed by `converge_boot_mode.yml`,
`set_boot_mode.yml`, `stage_router.yml`, `test_hardware_e2e.yml`, and
`persist_uboot_env.yml` for router-side delegation) — set in
`inventory/group_vars/boards.yml` as `armbian_router: rb5009`.
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

## Per-host build profile layering

Board metadata and build configuration are expressed as three mergeable
inventory layers rather than a single collection-level boards metadata
dict. The resolver primitives in `playbooks/tasks/` merge them at
playbook-run time into a single fact per board.

**`armbian_board_config` layers** (merged by `_resolve_board_config.yml`):

| Layer | Inventory location | Scope |
|---|---|---|
| `armbian_board_config_family` | `inventory/group_vars/<family>.yml` | All boards in a SoC family (rk3588, rk3588s, …) |
| `armbian_board_config_model` | `inventory/group_vars/<model_group>.yml` | One specific board model (orange-pi-5-pro, rock-5b, …) |
| `armbian_board_config_host` | `host_vars/<hostname>.yml` (optional) | One specific physical board instance |

Model keys win over family; host keys win over model. The resolved
`armbian_board_config` fact is the union with later layers taking
precedence. Fields: `dtb`, `console`, `earlycon`, `armbian_board_name`,
`armbian_dl_dir`, `armbian_support`, `local_kernel` (optional).

**`armbian_build` layers** (merged by `_resolve_build_profile.yml`):

| Layer | Inventory location | Scope |
|---|---|---|
| `armbian_build_family` | `inventory/group_vars/<family>.yml` | SoC-family defaults (shared branch, family-level userpatches) |
| `armbian_build_model` | `inventory/group_vars/<model_group>.yml` | Model-specific build settings (branch override, model userpatches) |
| `armbian_build_host` | `host_vars/<hostname>.yml` (optional) | Per-host build overrides (rare; e.g. pinning a custom fork) |

The resolved `armbian_build` fact feeds `armbian_build_board`,
`armbian_build_branch`, `armbian_build_release`, and
`armbian_build_userpatches` directly into the `image_build` role.
Family-level `userpatches` and model-level `userpatches` are concatenated
(family first, model second) before the host layer is merged.

**`armbian_rootfs_src` resolution** (`_resolve_rootfs_src.yml`):

1. Host `armbian_rootfs_src` (host_vars) — explicit per-host pin.
2. Published manifest on the netboot server (`armbian_nfs_assets_export/images/<inventory_hostname>/manifest.json`) — derived from the last successful `build_and_publish_from_inventory.yml` run.
3. Fail with a clear message listing the two lookup paths.

## How netboot content is managed

Two staging playbooks write the server-side state:

`stage_netboot_assets.yml` connects to the netboot server (TrueNAS) over SSH
(`hosts: netboot_server`, `become: true`) and invokes the `rootfs_provision`
role once per board host. For each host, `rootfs_provision` resolves the
`.img.xz` source (via `_resolve_rootfs_src.yml`: host_vars `armbian_rootfs_src`
→ published manifest → fail), extracts the rootfs into the per-model template
directory, reflink-clones it into the per-host directory, and resets identity.
The role accepts a `.img.xz` source as either a local path on the server or an
`http(s)://` URL.

`stage_router.yml` is a 3-play composition: play 1 fetches the per-model
kernel/initrd/dtb from `netboot_server` to the controller cache; play 2
imports the transport-specific upload playbook (defaults to
`routeros/upload_tftp_assets.yml`); play 3 imports the plumbing-check
reference to verify rows landed.

Inside `armbian_nfs_rootfs_path` two layouts coexist:

```
armbian_nfs_rootfs_path/
├── _templates/
│   └── orange-pi-5-pro/    per-model template (extracted from .img.xz)
└── orange-pi-5-pro-01/     per-host clone of _templates/orange-pi-5-pro
```

Per-host clones are made with `cp --reflink=auto`, which is a zero-cost CoW
snapshot on XFS, btrfs, and ZFS. Hostname, machine-id, and SSH host keys are
reset per-host so two same-model boards have independent identity on the wire —
see `roles/rootfs_provision/tasks/_identity_reset.yml`.

`converge_boot_mode.yml` is a four-play composition: pre-flight plumbing
check (router), local pxelinux render (boards, delegated to localhost),
upload reference playbook (router, swappable transport), and cycle+wait+verify
on boards. The control node never NFS-mounts anything and never SSHes to the
netboot server during boot-mode convergence.

## Where things run

| Playbook | Runs on |
|---|---|
| `bootstrap_armbian.yml` | **boards** (connects as root with `armbian_default_password`; idempotent) |
| `routeros/bootstrap_user.yml` | RouterOS (router + switches via `routeros_netboot`) |
| `stage_netboot_assets.yml` | **netboot server** (`rootfs_provision` per host: extract template + reflink-clone + identity reset) |
| `stage_router.yml` | **netboot server** (fetch to controller) + **rb5009** (net_put + /ip tftp registration + plumbing check) |
| `build_and_publish_from_inventory.yml` | **`armbian_builders`** (Docker-capable build host; loops per-host after resolving `armbian_build` profile); publishes to **netboot server** over SSH |
| `converge_boot_mode.yml` / `set_boot_mode.yml` | **rb5009** (plumbing check + pxelinux upload) + **boards** (pxelinux render via delegate localhost, PoE cycle + wait + verify) |
| `poe_control.yml` | **boards** (delegated to `routeros_switch` via `armbian_poe_switch` hostvar) |
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
pre-flight decisions, inventory placeholders, board metadata fields
(including `earlycon`), U-Boot branch selection (`current` vs `edge`
via `armbian_build_model.branch` in inventory group_vars), post-build defconfig audits (CONFIG_PCI_INIT_R,
PHY drivers, NIC driver presence), and ends at
`stage_netboot_assets.yml` + `stage_router.yml`. It also encodes the
decision rule for running Approach B (`persist_uboot_env.yml`) based on
whether the board's U-Boot defconfig sets `CONFIG_ENV_IS_IN_SPI_FLASH=y`.

Minimum touched files for a new board (collection edits are not required —
all board metadata lives in inventory):

1. `inventory/hosts.yml` (doc-only example) + your real inventory:
   add the host(s) under a new per-model subgroup of `boards` with
   `armbian_board_mac`, `armbian_board_model`,
   `armbian_boot_mode`, `armbian_poe_switch`,
   `armbian_poe_port`.
2. `inventory/group_vars/<family>.yml` (or create it): set
   `armbian_board_config_family` with the SoC-family-level board fields
   (console, earlycon, dtb defaults that apply to all boards in the family).
3. `inventory/group_vars/<model_group>.yml` (create): set
   `armbian_board_config_model` with model-specific fields (`armbian_dl_dir`,
   `armbian_board_name`, `armbian_support`, `dtb`, `console`, `earlycon`)
   and `armbian_build_model` with build fields (branch, release,
   userpatches). The `armbian_board_model` in hosts.yml ties the host to
   this group.
4. (Optional) `host_vars/<hostname>.yml`: set `armbian_rootfs_src` to an
   `https://`, `http://`, or absolute-path `.img.xz` URL if you want to
   pin a specific image for this host rather than using the published
   manifest. When omitted, `_resolve_rootfs_src.yml` derives the URL
   from the netboot server's published manifest automatically.

### Where to put a new armbian/build hook

Two overlay paths are available; choose by SCOPE:

- **Family-shared** — the hook applies identically to every board in a SoC family (e.g. rk3588). Add it to `armbian_build_family.userpatches` in `inventory/group_vars/<family>.yml` (e.g. `rk3588.yml`) under `dest: config/sources/families/<family>.conf`. Today's examples: `__999_pxe_first`, `__999_local_kernel_bake`, `__999_no_bcmdhd_for_netboot`.
- **Per-board** — the hook applies to ONE board (different `BOOTBRANCH`, different `UBOOT_TARGET_MAP`, different patchdir, etc.). Add it to `inventory/group_vars/<model_group>.yml` under `armbian_build_model.userpatches` with `dest: config/boards/<board>.conf`. armbian/build only sources that overlay when building the matching board, so the per-board scope is structural — no `if BOARD == ...` filter needed. Today's examples: `__999_rock5a_use_mainline_uboot`, `__999_rock5b_uboot_v2026_04`.

If you find yourself adding `[[ "${BOARD}" != "..." ]] && return 0` inside a family-level hook, that's the cue to write a per-board overlay instead.

**Userpatches overlay files persist across rebuilds.** The `image_build` role writes `userpatches/config/{sources/families,boards}/<file>.conf` via `ansible.builtin.copy` (overwrite-style), so renaming an existing overlay file or removing it from `armbian_build_family.userpatches` / `armbian_build_model.userpatches` in inventory leaves a stale file on the builder host that armbian/build will continue to source. After such a change, manually delete the orphan from `${armbian_build_cache_dir}/build/userpatches/` on the builder, or run the next build with a fresh `armbian_build_cache_dir`.

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
`armbian_poe_switch` host variable. The `delegate_to` pattern works because
`group_vars/routeros.yml` sets `ansible_connection: ansible.netcommon.network_cli` on
all RouterOS hosts, so the delegated task uses the switch's connection settings
automatically.

The role supports three actions via `-e armbian_poe_action=`:
- `on` — sets `poe-out=auto` (default)
- `off` — sets `poe-out=off`
- `cycle` — off, pause (`armbian_poe_cycle_delay` seconds, default 5), then on

PoE uses delegation because boards may be connected to different switches. Each board
knows its own switch and port, so delegation routes the command correctly without
filtering.

## Key files

- `inventory/group_vars/all.yml` (armbian_build_defaults) — build-time defaults (armbian_build_release, armbian_build_ref, etc.); loaded automatically by inventory, no include_vars needed
- `roles/rootfs_provision/tasks/main.yml` — per-host: resolve src → extract template → reflink-clone → identity reset
- `roles/rootfs_provision/tasks/_identity_reset.yml` — reset hostname/machine-id/SSH host keys in a rootfs
- `roles/disk_image/tasks/main.yml` — orchestrate validate → write → settle for the disk-imaging role
- `roles/disk_image/tasks/_validate.yml` — mount-aware guard + extension classify (pre-flight)
- `roles/disk_image/tasks/_write.yml` — four-branch streaming write with pipefail propagation
- `roles/pxelinux_render/tasks/main.yml` — render one per-board pxelinux.cfg locally
- `roles/pxelinux_render/templates/pxelinux_cfg.j2` — multi-label, default-driven PXE config
- `roles/board_boot_wait/tasks/main.yml` — TCP/22 + SSH wait on a board (no power knowledge)
- `roles/board_boot_verify/tasks/main.yml` — assert rootfs fstype matches declared boot mode
- `playbooks/tasks/_resolve_board_config.yml` — merge family/model/host layers → `armbian_board_config` fact
- `playbooks/tasks/_resolve_build_profile.yml` — merge family/model/host build layers → `armbian_build` fact
- `playbooks/tasks/_resolve_rootfs_src.yml` — derive per-host `armbian_rootfs_src` from host_vars or published manifest
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
- `inventory/group_vars/all.yml` — IPs, NFS paths, cross-role defaults (edit before first run)
- `inventory/group_vars/boards.yml` — `armbian_router` + retry-knob overrides
- `playbooks/build_and_publish_from_inventory.yml` — custom Armbian image build pipeline (per-host loop)
- `playbooks/persist_uboot_env.yml` — Approach B for rock-5b autonomous PXE
- `docs/boot-mode-override.md` — three boot mode override methods (inventory, -e, U-Boot env)
- `docs/retry-configuration.md` — retry/timeout knob recipes
- `docs/runbooks/reprovision-local-disk.md` — disk_provision lifecycle runbook
- `galaxy.yml` — collection namespace, version (0.0.2-alpha), external dependencies
