# david_igou.armbian_netboot

![Galaxy Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgalaxy.ansible.com%2Fapi%2Fv3%2Fplugin%2Fansible%2Fcontent%2Fpublished%2Fcollections%2Findex%2Fdavid_igou%2Farmbian_netboot%2F&query=%24.highest_version.version&label=galaxy)
![Ansible](https://img.shields.io/badge/ansible-%3E%3D2.15-blue?logo=ansible)
![CI](https://img.shields.io/github/actions/workflow/status/david-igou/ansible-collection-armbian_netboot/tests.yml?branch=main&label=CI)
![License](https://img.shields.io/github/license/david-igou/ansible-collection-armbian_netboot)
![Last Commit](https://img.shields.io/github/last-commit/david-igou/ansible-collection-armbian_netboot)

Ansible collection that delivers a single capability: an `orange-pi-5-pro`
board can be flipped between booting its on-SD Armbian rootfs and an NFS
rootfs by toggling one RouterOS DHCP option set. The collection is organised
as a small set of single-purpose **roles** (primitives) and **workflow
playbooks** that compose them — see [Mental model](#mental-model) below.

## Status: v1 = orange-pi-5-pro netboot capability only

This collection is currently scoped to a single deliverable: a custom
Armbian SD image for `orange-pi-5-pro` whose U-Boot tries PXE first, so
toggling a RouterOS DHCP option set switches the board between an NFS
rootfs and the local SD rootfs. v1 explicitly does not include
reprovisioning, on-host bootloader flashing, or any board other than
`orange-pi-5-pro`. Reprovisioning and on-host bootloader flashing have
been **deleted from the repo, not deferred-in-place**; they will be
re-introduced post-v1 against the slimmer model.

The "what runs over NFS / why" question is deferred — v1 just
demonstrates that a board can be flipped between SD and NFS via DHCP.
See `playbooks/test_hardware_e2e.yml` for the assertion harness.

Spec: [`docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`](docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md)

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
- A running netboot.xyz instance with NFS exports accessible from the Ansible
  control node. Path defaults match the
  [netboot.xyz container](https://github.com/netbootxyz/docker-netbootxyz):
  TFTP root `/config/menus/` and HTTP root `/assets/` on port 80. Override
  `tftp_nfs_export` / `nfs_assets_export` / `image_server_url` in
  `group_vars/all.yml` if you serve TFTP/HTTP differently.
- A MikroTik RouterOS device with SSH access and a DHCP server configured.
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
| [`bootstrap_armbian`](roles/bootstrap_armbian/) | SSH-key user with passwordless sudo on a freshly flashed Armbian board |
| [`bootstrap_routeros_user`](roles/bootstrap_routeros_user/) | RouterOS user, group, and SSH-key state over network_cli |
| [`nfs_content`](roles/nfs_content/) | rootfs / TFTP / pxelinux content under server exports |
| [`routeros_dhcp`](roles/routeros_dhcp/) | Shared `armbian-nfsroot` DHCP option set + per-lease assignment on RouterOS |
| [`routeros_poe`](roles/routeros_poe/) | PoE port state (on/off) on RouterOS switch ports |

### Playbooks

| # | Playbook | Frequency | What it does |
|---|---|---|---|
| 0 | `build_image.yml` | Per board model, on `armbian/build` ref or patch-table change | Builds a custom Armbian `.img.xz` for `orange-pi-5-pro` on the `armbian_builders` host and publishes it to the netboot server's HTTP root for `populate_nfs_content` to consume. |
| 1 | `bootstrap_armbian.yml` | Once per board, right after flashing the custom image | Connects as root with `armbian_default_password`, creates the inventory's `ansible_user` with passwordless sudo + SSH-key auth, drops Armbian's first-login TUI prompt, disables sshd password auth. |
| 2 | `bootstrap_routeros_user.yml` | Once per RouterOS device | Provisions the `ansible-netboot` SSH user, group, and keys on the router (and any switches). |
| 3 | `populate_nfs_content.yml` | Once per environment, then on every inventory change | Populates the netboot server's NFS rootfs templates, per-host clones, and TFTP kernel/initrd/DTB tree from the Armbian image. |
| 4 | `setup_routeros_dhcp.yml` | Once per RouterOS device | Creates the shared `armbian-nfsroot` DHCP option set on RouterOS. |
| 5 | `enable_netboot.yml` | Ad-hoc | Sets the board's RouterOS lease to `dhcp-option=armbian-nfsroot` and reboots it; the board comes up on the NFS rootfs. |
| 6 | `disable_netboot.yml` | Ad-hoc | Clears the RouterOS DHCP option for a board; the next reboot lands on the local SD rootfs. |
| 7 | `poe_control.yml` | Ad-hoc | Power-cycles, powers off, or powers on a board via its upstream RouterOS PoE switch port. |
| — | `test_hardware_e2e.yml` | Ad-hoc | Hardware regression test: drives a single board through SD → nfsroot → SD via RouterOS DHCP toggle and PoE cycles, asserting `findmnt /` reports the expected source at each transition. |

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

#### 0.3 Populate the NFS exports

```bash
ansible-playbook playbooks/populate_nfs_content.yml
```

Runs over SSH against the netboot server. Pre-flight HEAD-checks every
`armbian_image_urls` entry (failing on 4xx/dead mirror) before any
destructive work. For each unique `board_model` in inventory, downloads
the image, extracts the rootfs into `nfs_rootfs_path/_templates/<model>/`,
and stages kernel/initrd/DTB into the TFTP tree. For each inventory host,
reflink-clones the model template into `nfs_rootfs_path/<inventory_hostname>/`
and resets hostname / machine-id / SSH host keys so per-host identity is
independent. Idempotent — re-run on inventory or image changes.

#### 0.4 Create the RouterOS DHCP option objects

```bash
ansible-playbook playbooks/setup_routeros_dhcp.yml
```

Idempotently creates the `armbian-tftp-server` and `armbian-nfsroot-bootfile`
options and the `armbian-nfsroot` option set on RouterOS. Per-board state
on RouterOS is exclusively the `dhcp-option` field on each static lease,
managed by `enable_netboot.yml` / `disable_netboot.yml`. Re-run after
RouterOS firmware upgrades that may have reset `/ip dhcp-server option`
state.

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
are `root` / `armbian_default_password` (1234) until first interactive
login replaces them.

#### 1.3 Add the board to inventory

Edit `inventory/hosts.yml`. Each host needs `board_mac` and `board_model`,
where `board_model` matches a key in [`vars/boards.yml`](vars/boards.yml):

```yaml
boards:
  children:
    orange_pi_5_pro:
      hosts:
        orange-pi-5-pro-01:
          ansible_host: 192.168.1.131
          board_mac: "aa:bb:cc:dd:ee:11"
          board_model: orange-pi-5-pro
```

For PoE-powered boards, also set `poe_switch` (inventory hostname of the
RouterOS switch supplying power) and `poe_port` (interface name on that
switch, e.g. `ether3`).

#### 1.4 Bootstrap the board's SSH user

```bash
ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01
```

Connects as `root` with `armbian_default_password`, creates the inventory's
`ansible_user` with passwordless sudo + SSH-key auth, drops Armbian's
first-login TUI prompt, and disables sshd password auth. Idempotent — a
second run is a no-op aside from authorized_keys reconciliation.

Edit the SSH key list in `playbooks/bootstrap_armbian.yml` (or override
`bootstrap_armbian_ssh_keys` via `-e`) before first run.

#### 1.5 Re-run populate_nfs_content.yml

```bash
ansible-playbook playbooks/populate_nfs_content.yml
```

Creates the per-host rootfs clone for the new host. Existing boards are
unaffected; the per-model template extraction step is skipped if it's
already populated.

The board is now **fully onboarded**. It will participate in the
toggle-and-revert lifecycle below indefinitely without further setup.

---

## Daily operations

### Boot a board into NFS root

```bash
ansible-playbook playbooks/enable_netboot.yml --limit orange-pi-5-pro-01
```

Sets `dhcp-option=armbian-nfsroot` on the board's RouterOS lease and
reboots it. U-Boot DHCPs, gets `next-server`, PXE-boots into the NFS
rootfs. The board stays on NFS until you `disable_netboot`.

### Revert a board to disk boot

```bash
ansible-playbook playbooks/disable_netboot.yml --limit orange-pi-5-pro-01
```

Clears the board's RouterOS DHCP option and reboots. The next boot lands
on the SD rootfs.

### Power-cycle a board via PoE

When a board is wedged or unreachable, cycle its upstream RouterOS PoE
switch port instead of pulling cables:

```bash
# Hard power-cycle (off → wait poe_cycle_delay seconds → on)
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 -e poe_action=cycle

# Power off / on individually
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 -e poe_action=off
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 -e poe_action=on
```

The play targets `boards` with `gather_facts: false` (boards may be powered
off) and delegates the PoE command to each board's `poe_switch` via
`delegate_to`. Use `-e poe_cycle_delay=<seconds>` to override the off→on
dwell (default 5s).

### Hardware E2E test

```bash
ansible-playbook playbooks/test_hardware_e2e.yml --limit orange-pi-5-pro-01
```

Drives a single board through SD → nfsroot → SD via RouterOS DHCP toggle
and PoE cycles, asserting `findmnt /` reports the expected source at each
transition. Diagnostic bundle (cmdline, route, lsblk, U-Boot version,
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
| 3 | `populate_nfs_content.yml` | Once per environment + on every inventory change |
| 4 | `setup_routeros_dhcp.yml` | Once per RouterOS device |
| 5 | `enable_netboot.yml --limit <host>` | Ad-hoc — toggle into NFS root |
| 6 | `disable_netboot.yml --limit <host>` | Ad-hoc — revert to SD rootfs |
| 7 | `poe_control.yml --limit <host> -e poe_action=cycle` | Ad-hoc PoE power-cycle (`on`/`off`/`cycle`) |
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
