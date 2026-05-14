# david_igou.armbian_netboot

![Galaxy Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgalaxy.ansible.com%2Fapi%2Fv3%2Fplugin%2Fansible%2Fcontent%2Fpublished%2Fcollections%2Findex%2Fdavid_igou%2Farmbian_netboot%2F&query=%24.highest_version.version&label=galaxy)
![Ansible](https://img.shields.io/badge/ansible-%3E%3D2.15-blue?logo=ansible)
![CI](https://img.shields.io/github/actions/workflow/status/david-igou/ansible-collection-armbian_netboot/tests.yml?branch=main&label=CI)
![License](https://img.shields.io/github/license/david-igou/ansible-collection-armbian_netboot)
![Last Commit](https://img.shields.io/github/last-commit/david-igou/ansible-collection-armbian_netboot)

Ansible collection that delivers a single capability: an `orange-pi-5-pro`
board can be flipped between booting its on-SD Armbian rootfs and an NFS
rootfs while keeping a per-board `pxelinux.cfg/01-<MAC>` file **always**
present on the rb5009 router's TFTP server — the `default` directive inside
that file selects the active boot mode (`nfs` vs `sd`). The collection is
organised as a small set of single-purpose **roles** (primitives) and
**workflow playbooks** that compose them — see [Mental model](#mental-model)
below.

## Status: v2.0.0 — always-netboot model

Every onboarded board always has `pxelinux.cfg/01-<MAC>` on rb5009; boot mode
is controlled by inventory (`armbian_netboot_boot_mode: nfs \| sd`) and the
matching `default` label in the rendered pxelinux file — not by
presence/absence of the file. A custom Armbian SD image for `orange-pi-5-pro`
whose U-Boot tries PXE first enforces that PXE consults rb5009 on every boot.

Sd boot requires `armbian_netboot_sd_partuuid` on the host. See
`playbooks/test_hardware_e2e.yml` for the assertion harness.

Spec: [`docs/superpowers/specs/2026-05-14-always-netboot-migration-design.md`](docs/superpowers/specs/2026-05-14-always-netboot-migration-design.md)

## Mental model

**Roles are single-purpose, parameter-driven state enforcers. Playbooks
compose them into workflows.**

A role asks: *given these inputs, is the world in the desired state, and if
not, make it so.* It does not decide intent — callers do. A playbook decides
which roles to invoke, against which inventory, with which parameters, in
what order.

Adding a new external system means adding a role. Adding a new operation
that combines existing primitives means adding a playbook (no role changes).

## Requirements

- Ansible >= 2.15
- A netboot server (e.g. a TrueNAS host) reachable over SSH that exports the
  per-host NFS rootfs to the boards. The HTTP assets root defaults match the
  homelab's public nginx container on TrueNAS — host-side path
  `/mnt/ssd/public/boot-files`, reachable at `https://public.igou.systems/boot-files/`.
  Override `armbian_netboot_nfs_assets_export` in `group_vars/all.yml` if you serve HTTP from
  a different path.
- A MikroTik RouterOS rb5009 with SSH access. The collection writes per-board
  `pxelinux.cfg/01-<MAC>` (always present; boot mode via `default`) and per-model kernel/initrd/dtb under `flash:/sbc/` (override path segment via `armbian_netboot_tftp_flash_dir`, default `sbc`)
  and registers corresponding `/ip tftp` rows; no DHCP option-sets or lease
  mutations. The SBC subnet's `next-server` must already point at rb5009
  (owned externally — typically by your routeros-config repo).
- A Docker-capable build host (for `build_image.yml`) reachable as the
  `armbian_builders` inventory group.

### Collection dependencies

| Collection | Version |
|---|---|
| `community.routeros` | >= 2.0.0 |
| `ansible.posix` | >= 1.5.0 |
| `ansible.netcommon` | >= 5.0.0 |

## Included content

### Roles

| Role | Enforces / produces |
|---|---|
| [`armbian_build`](roles/armbian_build/) | Custom Armbian `.img.xz` with PXE-first U-Boot baked in, published to the netboot server |
| [`boot_mode`](roles/boot_mode/) | Board converged to `armbian_netboot_boot_mode` (`nfs` \| `sd`): pxelinux.cfg + PoE cycle + rootfs verify |
| [`bootstrap_armbian`](roles/bootstrap_armbian/) | SSH-key user with passwordless sudo on a freshly flashed Armbian board |
| [`bootstrap_routeros_user`](roles/bootstrap_routeros_user/) | RouterOS user, group, and SSH-key state over network_cli |
| [`netboot_assets`](roles/netboot_assets/) | Per-host NFS rootfs on the netboot server + per-model kernel/initrd/dtb on rb5009 |
| [`routeros_pxe_config`](roles/routeros_pxe_config/) | Per-board `pxelinux.cfg/01-<MAC>` + `/ip tftp` row on rb5009 |
| [`routeros_poe`](roles/routeros_poe/) | PoE port state (on/off) on RouterOS switch ports |

### Playbooks

| # | Playbook | Frequency | What it does |
|---|---|---|---|
| 0 | `build_image.yml` | Per board model, on `armbian/build` ref or patch-table change | Builds a custom Armbian `.img.xz` for `orange-pi-5-pro` on the `armbian_builders` host and publishes it to the netboot server's HTTP root for `stage_nfs_rootfs.yml` / `stage_tftp_assets.yml` to consume. |
| 1 | `bootstrap_armbian.yml` | Once per board, right after flashing the custom image | Connects as root with `armbian_netboot_default_password`, creates the inventory's `ansible_user` with passwordless sudo + SSH-key auth, drops Armbian's first-login TUI prompt, disables sshd password auth. |
| 2 | `bootstrap_routeros_user.yml` | Once per RouterOS device | Provisions the `ansible-netboot` SSH user, group, and keys on the router (and any switches). |
| 3 | `stage_nfs_rootfs.yml` | Once per environment, then on every inventory change | Against the netboot server: pre-flight URL checks, image extraction, per-model NFS templates and per-host rootfs clones. |
| 4 | `stage_tftp_assets.yml` | After NFS staging or when kernel/initrd/dtb change | Against rb5009: `net_put` per-model kernel/initrd/DTB under `flash:/sbc/` (`armbian_netboot_tftp_flash_dir`, default `sbc`) and register `/ip tftp` rows. |
| 5 | `converge_boot_mode.yml` | Ad-hoc or whenever inventory boot mode changes | Converges each targeted board to its inventory-declared `armbian_netboot_boot_mode` (pxelinux `default` + PoE cycle + verify). |
| 6 | `set_boot_mode.yml` | Ad-hoc override (`-e armbian_netboot_boot_mode=...`) | Same convergence path without editing inventory — e.g. `-e armbian_netboot_boot_mode=sd` for SD rootfs. |
| 7 | `poe_control.yml` | Ad-hoc | Power-cycles, powers off, or powers on a board via its upstream RouterOS PoE switch port. |
| — | `test_hardware_e2e.yml` | Ad-hoc | Hardware regression test: drives a single board through SD → nfsroot → SD via pxelinux `default`/PoE cycles, asserting `findmnt /` reports the expected source at each transition. |

## Installation

```bash
ansible-galaxy collection install david_igou.armbian_netboot
```

Or in a `requirements.yml`:

```yaml
---
collections:
  - name: david_igou.armbian_netboot
```

---

## Lifecycle

### Phase 0 — One-time control-plane setup

Done once per environment, before adding any boards.

#### 0.1 Build the custom Armbian image

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/build_image.yml
```

Runs on the `armbian_builders` host (Docker-capable). The `armbian_build`
role clones `armbian/build`, applies the PXE-first `BOOT_TARGETS` patch via
`armbian/build`'s `pre_config_uboot_target__<board>_*` hook, builds a
`.img.xz` for `orange-pi-5-pro`, and publishes it to the netboot server's
HTTP assets directory. Re-run after changes to the patch table or the
pinned `armbian/build` ref.

#### 0.2 Provision the RouterOS user

```bash
ansible-playbook playbooks/bootstrap_routeros_user.yml \
  -e ansible_user=<existing-admin>
```

Targets the `routeros_netboot` group (router + any switches). The
`-e ansible_user=...` overrides the inventory-set `ansible-netboot` for
this bootstrap run only — that user does not yet exist on the router. The
role idempotently creates the `ansible-netboot` user, group, and SSH keys.
From this point on every other playbook authenticates as `ansible-netboot`.

#### 0.3 Stage NFS rootfs (netboot server)

```bash
ansible-playbook playbooks/stage_nfs_rootfs.yml
```

Against the netboot server over SSH: pre-flight HEAD-checks every
`armbian_netboot_image_urls` entry (failing on 4xx/dead mirror)
before any destructive work; for each unique `armbian_netboot_board_model` in inventory,
downloads the image, extracts the rootfs into
`armbian_netboot_nfs_rootfs_path/_templates/<model>/`, and reflink-clones a per-host
rootfs into `armbian_netboot_nfs_rootfs_path/<inventory_hostname>/` with hostname /
machine-id / SSH host keys reset for unique identity.

#### 0.4 Stage TFTP assets (rb5009)

```bash
ansible-playbook playbooks/stage_tftp_assets.yml
```

Against rb5009 over network_cli: copies kernel/initrd/DTB from the control-node cache
(`armbian_netboot_tftp_cache_dir`) into `flash:/sbc/armbian/<model>/` and registers a `/ip tftp` row per file.

Re-run 0.3–0.4 on inventory or image changes; both plays are idempotent.

### Phase 1 — Adding a board

Repeated once per physical board.

#### 1.1 Flash the custom Armbian image to an SD card (manual)

Use any tool you like — `xzcat | dd`, `etcher`, the Armbian installer — to
write the `.img.xz` produced by `build_image.yml` (published to the netboot
server's HTTP assets directory in step 0.1) to an SD card. This is the only
step in the lifecycle that this collection does not automate; everything
from here on runs over SSH.

#### 1.2 Insert the SD card and power the board on

The board obtains a DHCP lease and responds to SSH. Default credentials
are `root` / `armbian_netboot_default_password` (1234) until first interactive
login replaces them.

#### 1.3 Add the board to inventory

Edit `inventory/hosts.yml`. Each host needs `armbian_netboot_board_mac`,
`armbian_netboot_board_model`, and `armbian_netboot_boot_mode` (`nfs` or `sd`). For
`sd`, also set `armbian_netboot_sd_partuuid`. The board model must match a key under
`armbian_netboot_board_configs` in [`vars/boards.yml`](vars/boards.yml):

```yaml
boards:
  children:
    orange_pi_5_pro:
      hosts:
        orange-pi-5-pro-01:
          ansible_host: 192.168.1.131
          armbian_netboot_board_mac: "aa:bb:cc:dd:ee:11"
          armbian_netboot_board_model: orange-pi-5-pro
          armbian_netboot_boot_mode: nfs
```

Group vars under `inventory/group_vars/boards.yml` must define `armbian_netboot_router`
(the RouterOS host that owns TFTP state for these boards — typically your rb5009 inventory name).

For PoE-powered boards, also set `armbian_netboot_poe_switch` (inventory hostname of the
RouterOS switch supplying power) and `armbian_netboot_poe_port` (interface name on that
switch, e.g. `ether3`).

#### 1.4 Bootstrap the board's SSH user

```bash
ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01
```

Connects as `root` with `armbian_netboot_default_password`, creates the inventory's
`ansible_user` with passwordless sudo + SSH-key auth, drops Armbian's
first-login TUI prompt, and disables sshd password auth. Idempotent — a
second run is a no-op aside from authorized_keys reconciliation.

Edit the SSH key list in `inventory/group_vars/all.yml` (see `armbian_netboot_bootstrap_ssh_keys`) or override
`armbian_netboot_bootstrap_ssh_keys` via `-e`) before first run. Optional: `armbian_netboot_bootstrap_user`.

#### 1.5 Re-run staging playbooks

```bash
ansible-playbook playbooks/stage_nfs_rootfs.yml
ansible-playbook playbooks/stage_tftp_assets.yml
```

Creates the per-host rootfs clone for the new host. Existing boards are
unaffected; the per-model template extraction step is skipped if it's
already populated.

The board is now **fully onboarded**. It will participate in the
toggle-and-revert lifecycle below indefinitely without further setup.

---

## Daily operations

### Converge a board to its declared boot mode

```bash
ansible-playbook playbooks/converge_boot_mode.yml --limit orange-pi-5-pro-01
```

Reads each host's `armbian_netboot_boot_mode` from inventory, renders `pxelinux.cfg/01-<MAC>`
(with `default` pointing at the nfs or sd label), `net_put`s it to rb5009, ensures the `/ip tftp`
row exists, PoE-cycles where applicable, and verifies the board reaches SSH with the expected rootfs.

### Override boot mode without editing inventory

```bash
ansible-playbook playbooks/set_boot_mode.yml --limit orange-pi-5-pro-01 -e armbian_netboot_boot_mode=nfs
ansible-playbook playbooks/set_boot_mode.yml --limit orange-pi-5-pro-01 -e armbian_netboot_boot_mode=sd
```

Same convergence mechanics as `converge_boot_mode.yml`, but the desired mode comes from `-e`.
Sd mode still requires `armbian_netboot_sd_partuuid` on the host.

### Power-cycle a board via PoE

When a board is wedged or unreachable, cycle its upstream RouterOS PoE
switch port instead of pulling cables:

```bash
# Hard power-cycle (off → wait armbian_netboot_poe_cycle_delay seconds → on)
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 -e armbian_netboot_poe_action=cycle

# Power off / on individually
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 -e armbian_netboot_poe_action=off
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 -e armbian_netboot_poe_action=on
```

The play targets `boards` with `gather_facts: false` (boards may be powered
off) and delegates the PoE command to each board's `armbian_netboot_poe_switch` via
`delegate_to`. Use `-e armbian_netboot_poe_cycle_delay=<seconds>` to override the off→on
dwell (default 5s).

### Hardware E2E test

```bash
ansible-playbook playbooks/test_hardware_e2e.yml --limit orange-pi-5-pro-01
```

Drives a single board through SD → nfsroot → SD via pxelinux boot-mode changes
and PoE cycles, asserting `findmnt /` reports the expected source at
each transition. Diagnostic bundle (cmdline, route, lsblk, U-Boot version,
journal) is emitted at every checkpoint. `-e leave_state=true` preserves
the failure state for forensic debugging. `-e capture_serial=true`
spawns a background socat capture from a USB-UART on the serial host
(defaults to `localhost`, override with `-e serial_host=<inventory-host>`,
`-e serial_device=`, `-e serial_baud=`) and tails the last 200 serial
lines at every checkpoint.

---

## Quick reference

| # | Playbook | Frequency |
|---|---|---|
| 0 | `build_image.yml` | Per `armbian/build` ref or patch-table change |
| 1 | `bootstrap_armbian.yml --limit <host>` | Once per board, right after flashing |
| 2 | `bootstrap_routeros_user.yml -e ansible_user=<existing-admin>` | Once per RouterOS device |
| 3 | `stage_nfs_rootfs.yml` | NFS templates + per-host rootfs on netboot server |
| 4 | `stage_tftp_assets.yml` | Kernel/initrd/dtb on rb5009 |
| 5 | `converge_boot_mode.yml --limit <host>` | Converge to inventory `armbian_netboot_boot_mode` |
| 6 | `set_boot_mode.yml --limit <host> -e armbian_netboot_boot_mode=nfs` (or `=sd`) | Ad-hoc boot mode override |
| 7 | `poe_control.yml --limit <host> -e armbian_netboot_poe_action=cycle` | Ad-hoc PoE power-cycle (`on`/`off`/`cycle`) |
| — | `test_hardware_e2e.yml --limit <host>` | Ad-hoc SD ↔ NFS hardware E2E test |

## Testing

[Molecule](https://ansible.readthedocs.io/projects/molecule/) scenarios live in
`extensions/molecule/`. Scenarios use a pluggable provisioner pattern so the same converge
and verify plays can run against either local containers or real VMs. Set the `PROVISIONER`
environment variable to switch (default: `podman`).

```bash
# Run the default scenario with podman
molecule test -s default

# Converge only (skip destroy)
molecule converge -s default

# Re-run verify against an already-converged instance
molecule verify -s default
```

The `default` scenario is currently a hello-world placeholder. Per-role scenarios will be
added as the collection matures; the boards and RouterOS device this collection targets
cannot be fully emulated, so most scenarios will be limited to syntax and check-mode runs.

## Makefile targets

| Target | Description |
|---|---|
| `make install` | Install external collection dependencies from `requirements.yml` |
| `make lint` | Run yamllint and ansible-lint |
| `make yamllint` | Run yamllint on `roles/`, `playbooks/`, `inventory/` |
| `make ansible-lint` | Run ansible-lint on `roles/` and `playbooks/` |
| `make molecule` | Run `molecule test` (override with `SCENARIO=<name>` and/or `PROVISIONER=<name>`) |
| `make test` | Run lint then molecule |
| `make collection-build` | Build the collection tarball |
| `make collection-install` | Build and install the collection locally |
| `make galaxy-import` | Run `galaxy-importer` locally (requires `pip install galaxy-importer`) |
| `make clean` | Remove build artefacts |

## Documentation

- [Architecture and boot flow](docs/architecture.md)
- [RouterOS setup guide](docs/routeros-setup.md)

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
