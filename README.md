# david_igou.armbian_netboot

![Galaxy Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgalaxy.ansible.com%2Fapi%2Fv3%2Fplugin%2Fansible%2Fcontent%2Fpublished%2Fcollections%2Findex%2Fdavid_igou%2Farmbian_netboot%2F&query=%24.highest_version.version&label=galaxy)
![Ansible](https://img.shields.io/badge/ansible-%3E%3D2.15-blue?logo=ansible)
![CI](https://img.shields.io/github/actions/workflow/status/david-igou/ansible-collection-armbian_netboot/tests.yml?branch=main&label=CI)
![License](https://img.shields.io/github/license/david-igou/ansible-collection-armbian_netboot)
![Last Commit](https://img.shields.io/github/last-commit/david-igou/ansible-collection-armbian_netboot)

Ansible collection for managing Armbian-based ARM single-board computers
end-to-end. The collection is organised as a small set of single-purpose
**roles** (primitives) and **workflow playbooks** that compose them. PXE-netboot
and reprovisioning are workflows built on top, not the framing — see
[Mental model](#mental-model) below.

> **⚠️ Status: netboot trigger is WIP pending the `armbian_build` role.** PXE-first
> requires a custom Armbian image, not stock — Rockchip `current` U-Boot ships
> `BOOT_TARGETS` with PXE at position 6, and `bootflow scan` lands on the SD card's
> `boot.scr` before reaching PXE. The flashing playbooks are correct in isolation but
> the full netboot trigger ("flip RouterOS DHCP option → board PXE-boots") doesn't
> deliver until the `armbian_build` role ships custom images with PXE-first U-Boot
> baked in at compile time. Tracked in
> [issue #16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16);
> empirical evidence in
> [issue #2](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/2).

**Sample inventory boards:** Orange Pi 5, Orange Pi 5 Pro, Orange Pi 5 Max, Rock 5B,
Rock 5A (Rockchip); Orange Pi Zero 3 (Allwinner).

## Mental model

**Roles are single-purpose, parameter-driven state enforcers. Playbooks
compose them into workflows.**

A role asks: *given these inputs, is the world in the desired state, and if
not, make it so.* It does not decide intent — callers do. A playbook decides
which roles to invoke, against which inventory, with which parameters, in
what order.

Adding a new external system means adding a role. Adding a new operation
that combines existing primitives means adding a playbook (no role changes).

The `bootloader` role keeps its per-SoC-family strategy structure; current
implementations cover Rockchip (RK3588/RK3588S/RK3399/RK356x via Armbian's
unified U-Boot format) and Allwinner (sunxi). Additional families add a SoC
vars file under `roles/bootloader/vars/socs/` plus, if the eMMC layout
differs, a per-strategy task file.

## Requirements

- Ansible >= 2.15
- A running netboot.xyz instance with NFS exports accessible from the Ansible control
  node. Path defaults match the [netboot.xyz container](https://github.com/netbootxyz/docker-netbootxyz):
  TFTP root `/config/menus/` and HTTP root `/assets/` on port 80. Override
  `tftp_nfs_export` / `nfs_assets_export` / `image_server_url` in
  `group_vars/all.yml` if you serve TFTP/HTTP differently.
- A MikroTik RouterOS device with SSH access and a DHCP server configured

### Collection dependencies

| Collection | Version |
|---|---|
| `community.routeros` | >= 2.0.0 |
| `ansible.posix` | >= 1.5.0 |
| `ansible.netcommon` | >= 5.0.0 |

## Included content

### Roles

| Role | Enforces / produces | Inputs |
|---|---|---|
| [`armbian_build`](roles/armbian_build/) ([#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16)) | `.img.xz` Armbian image with PXE-first U-Boot, published to netboot server | board, branch, release, patches, output path |
| [`bootloader`](roles/bootloader/) | U-Boot flashed on a target device (SPI / eMMC / SD) | board metadata, target device, apt source |
| [`bootstrap_armbian`](roles/bootstrap_armbian/) | SSH-key user with passwordless sudo on a freshly flashed Armbian board | user, key, sudoers policy |
| [`bootstrap_routeros_user`](roles/bootstrap_routeros_user/) | RouterOS user, group, SSH-key state over network_cli | user, group, key |
| [`nfs_content`](roles/nfs_content/) | rootfs / TFTP / pxelinux content under server exports | image URL, model, host identity, export paths |
| [`reprovision`](roles/reprovision/) | Armbian image flashed to a disk on the board | image URL, target device |
| [`routeros_dhcp`](roles/routeros_dhcp/) | shared DHCP option-set objects + per-lease assignment on RouterOS | RouterOS host, lease MAC, option-set name |
| [`routeros_poe`](roles/routeros_poe/) | PoE port state (on/off) on RouterOS switch ports | switch host, interface, action |

### Playbooks (in lifecycle order)

| # | Playbook | Frequency | What it does |
|---|---|---|---|
| 0 | `bootstrap_armbian.yml` | Once per board, right after flashing Armbian | Connects as root with `armbian_default_password`, creates the inventory's `ansible_user` with passwordless sudo + SSH key auth, drops Armbian's first-login TUI prompt, disables sshd password auth. |
| 1 | `bootstrap_routeros_user.yml` | Once per RouterOS device | Provisions the `ansible-netboot` SSH user, group, and keys on the router (and any switches) so subsequent playbooks can authenticate. |
| 2 | `populate_nfs_content.yml` | Once per environment, then on every inventory change | Populates the netboot server's NFS rootfs templates, per-host clones, and TFTP kernel/initrd/DTB tree from each board's Armbian image. |
| 3 | `setup_routeros_dhcp.yml` | Once per RouterOS device | Creates the shared `armbian-nfsroot` and `armbian-reprovision` DHCP option objects on RouterOS. |
| 4 | `flash_bootloader.yml` | Once per physical board (transition path for boards on stock images; superseded by `build_image.yml` once a board is onboarded to `armbian_build`) | Flashes PXE-first U-Boot to SPI / eMMC / SD — runs on the board itself over SSH. |
| 5 | `reprovision.yml` | Repeated per refresh | Full PXE → flash → disk boot cycle: enables PXE, reboots, flashes the disk, re-disables PXE, verifies disk boot. |
| — | `build_image.yml` ([#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16)) | Per board model, on `armbian/build` ref change | Builds a custom Armbian `.img.xz` for opted-in boards (`armbian_build_enabled: true`) on the `armbian_builders` group and publishes it to the netboot server's HTTP root for `populate_nfs_content`/`reprovision` to consume. |
| — | `enable_netboot.yml` | Ad-hoc | Boots a board into NFS root (read-only) for diagnostics or maintenance. |
| — | `disable_netboot.yml` | Ad-hoc | Reverts a board to local disk boot. |
| — | `poe_control.yml` | Ad-hoc | Power-cycles, powers off, or powers on a board via its upstream RouterOS PoE switch port. |
| — | `test_hardware_e2e.yml` | Ad-hoc | Repeatable hardware regression test for the PXE-first boot-mode invariant. Drives a single board (manually-flashed custom Armbian image) through disk → nfsroot → disk via RouterOS DHCP toggle and PoE cycles, asserting `findmnt /` reports the expected source at each transition. Diagnostic bundle (cmdline, route, lsblk, U-Boot deb version, journal) emitted at every checkpoint. `-e leave_state=true` preserves the failure state for forensic debugging. `-e capture_serial=true` spawns a background socat capture from a USB-UART on the control node (defaults `/dev/ttyUSB0` @ 1500000 baud; override with `-e serial_device=`, `-e serial_baud=`) and tails the last 200 serial lines at every checkpoint. |

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

## Lifecycle: from a brand-new SBC to ongoing provisioning

This section is the canonical end-to-end walkthrough. It covers everything from "I just
unboxed an SBC" through to ongoing reprovisioning. The earlier the step, the more likely
it only needs to happen once. The numbered subsection prefixes match the `#` column in the
playbook table above.

### Phase 0 — One-time control-plane setup

Done once per environment, before adding any boards.

#### 0.1 Configure inventory and global variables

The collection has two layers of configuration:

**`inventory/hosts.yml`** — host identity, including SSH connection details
(`ansible_host`, `ansible_user`, `ansible_port`) for the netboot server and RouterOS
devices. SSH connection settings live on the host entry, not in collection-level
variables; this is plain Ansible inventory. Three RouterOS-related groups partition
device roles:

```yaml
all:
  children:
    netboot_server:
      hosts:
        netboot-server:
          ansible_host: 192.168.1.10
          ansible_user: ansible
          ansible_become: true

    routeros:
      children:
        routeros_routers:    # devices that run a DHCP server
        routeros_switches:   # devices that don't, but should still get the SSH user

    routeros_routers:
      hosts:
        router:
          ansible_host: 192.168.1.1
          ansible_user: ansible-netboot   # provisioned in step 1 below
          ansible_port: 22

    routeros_netboot:        # subset to provision the SSH user on
      children:
        routeros_routers:
        routeros_switches:
```

The split matters because per-board playbooks (`enable_netboot.yml`,
`disable_netboot.yml`, `reprovision.yml`) and `setup_routeros_dhcp.yml` all target
`routeros_routers` — running DHCP-mutating commands against switches would fail.
`bootstrap_routeros_user.yml` targets `routeros_netboot` (typically the same set as
`routeros`).

**`inventory/group_vars/all.yml`** — collection-level variables that are not SSH
connection details:

```yaml
netboot_server_ip: "192.168.1.10"     # default for both TFTP and NFS server IPs
routeros_dhcp_server_name: "dhcp1"    # /ip dhcp-server name on RouterOS
armbian_apt_suite: "bookworm"         # Armbian apt suite for preflight package validation
armbian_default_password: "1234"      # encrypt with ansible-vault before committing
```

**Split-host topology**: when TFTP/HTTP and NFS run on different IPs (e.g.
netboot.xyz container on a macvlan network at one address, NFS exported from the host
at another), override the two roles independently:

```yaml
tftp_server_ip: "10.10.45.242"   # netbootxyz container — DHCP option 66 + image_server_url
nfs_server_ip:  "10.10.9.213"    # NFS server — written into pxelinux.cfg's nfsroot=
```

When both roles share an address, leave both unset and just set `netboot_server_ip`.

The netboot server is **assumed to already be running** (netboot.xyz container + NFS
exports). The collection populates content into the existing exports — it does not stand
up the server itself. The export root paths (`nfs_rootfs_path`, `tftp_nfs_export`,
`nfs_assets_export`) must already exist and be exported read/write.

#### 0.2 Provision the RouterOS user (Playbook 1)

Run once against your RouterOS device(s) using an existing admin account. Targets the
`routeros_netboot` parent group, which covers both the router and any switches you want
provisioned with the same SSH-only admin user:

```bash
ansible-playbook playbooks/bootstrap_routeros_user.yml \
  -e ansible_user=<existing-admin> -e ansible_port=22
```

The `-e ansible_user=...` overrides the inventory-set `ansible-netboot` for this
bootstrap run only — at this point that user does not yet exist on the router. The role
idempotently creates the `ansible-netboot` user, an `ansible-netboot` group with the
permissions the collection needs, and installs the SSH keys the control node uses. From
this point on every other playbook authenticates as `ansible-netboot` over SSH key auth
(no API/REST).

#### 0.3 Populate the NFS exports (Playbook 2)

Once your `boards` group has at least one host and the corresponding `armbian_image_urls`
entry, run:

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/populate_nfs_content.yml
```

This runs against the netboot server over SSH and:

- Pre-flights every board's `uboot_apt_package` against the Armbian apt repo and HEAD-checks
  every `armbian_image_urls` entry. Misconfigurations fail here, before any destructive work.
- For each unique board model in inventory, downloads its Armbian image, extracts the
  rootfs into `nfs_rootfs_path/_templates/<model>/`, and stages kernel/initrd/DTB into
  the TFTP tree.
- For each inventory host, reflink-clones the model template into
  `nfs_rootfs_path/<inventory_hostname>/` and resets hostname / machine-id / SSH host
  keys so the host has independent identity on the wire.
- Publishes a copy of each `.img.xz` to the netboot server's HTTP assets directory so
  the reprovision role can fetch it from inside the NFS-booted environment.

Re-run this playbook whenever you add a new board model, change an image URL, or add a
new host to inventory. It is idempotent.

#### 0.4 Create the RouterOS DHCP option objects (Playbook 3)

```bash
ansible-playbook playbooks/setup_routeros_dhcp.yml
```

Idempotently creates the shared `dhcp-option` and option-set objects on RouterOS:

- `armbian-tftp-server` (option 66 = netboot server IP)
- `armbian-nfsroot-bootfile` (option 67 = nfsroot pxelinux.cfg path)
- `armbian-reprovision-bootfile` (option 67 = reprovision pxelinux.cfg path)
- `armbian-nfsroot` and `armbian-reprovision` option sets that bundle them

Per-board state on RouterOS is exclusively the `dhcp-option` field on each static lease,
managed by `enable_netboot.yml` / `disable_netboot.yml`. This playbook only manages the
shared object set; you typically only need to re-run it after RouterOS firmware upgrades
that may have reset `/ip dhcp-server option` state.

### Phase 1 — Onboarding a brand-new SBC

Repeated once per physical board.

#### 1.1 Flash Armbian to an SD card (manual, out-of-band)

Use any tool you like — `dd`, `etcher`, the Armbian installer, `xzcat | dd`, etc. — to write
the Armbian `.img.xz` for that board to an SD card. This is the only step in the entire
lifecycle that this collection does not automate; everything from here on runs over SSH.

#### 1.2 Insert the SD card and power the board on

Wait for it to come up on the network. The board should obtain a DHCP lease and respond
to SSH. The default credentials are `root` / `armbian_default_password` (1234) until
first interactive login replaces them.

> **Why SD even on boards with NVMe?** PXE-first U-Boot must live on a device the SoC's
> BootROM can load before the kernel is involved. NVMe is not a viable U-Boot host on most
> ARM SBCs; SPI / eMMC / SD are. The "SD-only" boards in the sample inventory keep their
> rootfs on NVMe in normal operation — the SD card is only the bootloader.

#### 1.3 Add the board to inventory

Edit `inventory/hosts.yml`. Each host needs `board_mac` and `board_model` set, where
`board_model` matches a key in [`roles/bootloader/vars/boards.yml`](roles/bootloader/vars/boards.yml):

```yaml
boards:
  children:
    rock_5b:
      hosts:
        rock-5b-01:
          ansible_host: 192.168.1.131
          board_mac: "aa:bb:cc:dd:ee:31"
          board_model: rock-5b
```

If the board's specific unit diverges from the model defaults — e.g. SPI not populated,
NVMe at a non-default path, eMMC retrofitted — set `host_board_overrides` on that host.
See the commented example in [`inventory/hosts.yml`](inventory/hosts.yml).

If you're using a board model not yet in `boards.yml`, add an entry there first. See
[docs/board-bootloader.md](docs/board-bootloader.md) for the field reference.

#### 1.4 Bootstrap the board's SSH user (Playbook 0)

```bash
ansible-playbook playbooks/bootstrap_armbian.yml --limit rock-5b-01
```

Connects as `root` with `armbian_default_password` (1234 on a stock image), creates the
inventory's `ansible_user` with passwordless sudo + SSH-key auth, drops Armbian's
first-login TUI prompt (`/root/.not_logged_in_yet` — would otherwise hang `apt install`
in step 1.7), and disables sshd password auth. Idempotent — re-running on an
already-bootstrapped board is a no-op aside from authorized_keys reconciliation.

Edit the SSH key list in `playbooks/bootstrap_armbian.yml` (or override
`bootstrap_armbian_ssh_keys` via `-e`) before first run.

#### 1.5 Add the image URL

Edit `inventory/group_vars/all.yml`:

```yaml
armbian_image_urls:
  rock-5b: "https://dl.armbian.com/rock-5b/Armbian_..."
```

Pin the full versioned URL or an Armbian-published alias (e.g.
`Noble_current_minimal`). Pre-flight in `populate_nfs_content.yml` HEAD-checks this URL.

#### 1.6 Re-run populate_nfs_content.yml

```bash
ansible-playbook playbooks/populate_nfs_content.yml
```

This builds the NFS rootfs and TFTP staging for the new board model (if new) and creates
the per-host rootfs clone for this specific host. Existing boards are unaffected (the
extraction step is skipped if the model template is already populated).

#### 1.7 Flash PXE-first U-Boot to the board (Playbook 4)

This is the bootloader step. It runs on the board itself over SSH, regardless of which
flash target the board ends up using:

```bash
ansible-playbook playbooks/flash_bootloader.yml --limit rock-5b-01
```

The role auto-resolves the flash target from the board's capability flags:

- `has_spi=true` and SPI detected → write `u-boot-rockchip-spi.bin` to the SPI MTD device.
- Else `has_emmc=true` → write to the eMMC boot partition (Rockchip) or eMMC user-area
  sector 16 (Allwinner).
- Else → write to the SD card the board is **currently booted from**, in place, at the
  SoC family's `sd_uboot_seek_sectors` offset (Rockchip 64, Allwinner 16). Hard-fails if
  the rootfs is not on a removable SD card.

The U-Boot binary the role installs is *PXE-capable* (`BOOTSTD_DEFAULTS=y`,
`CONFIG_BOOTCOMMAND="bootflow scan -lb"`, `CONFIG_CMD_PXE=y`). Whether the board
*actually* tries PXE before disk on each boot depends on the binary's compile-time
`BOOT_TARGETS` ordering. Stock Armbian Rockchip `current` debs put PXE at position 6,
which means PXE is unreachable in practice — see
[#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16) for
the `armbian_build` role that produces custom **images** with PXE-first ordering
baked into U-Boot at compile time. (`flash_bootloader.yml` remains useful as the
transition path for boards still running stock images; once a board is onboarded
to `armbian_build`, `build_image.yml` + `reprovision.yml` replaces it.) The
bootloader role cannot tweak this from the board side (`CONFIG_ENV_IS_NOWHERE=y`).

To force a target, override:

```bash
ansible-playbook playbooks/flash_bootloader.yml --limit rock-5b-01 -e bootloader_target=spi
ansible-playbook playbooks/flash_bootloader.yml --limit opi-zero3-01 -e bootloader_target=sd
```

After this step the board is dormant from a netboot perspective: with no DHCP option set,
DHCP returns no `next-server`, the PXE attempt fails, and U-Boot falls through to disk.
The board behaves exactly as it did before, until you flip it via `enable_netboot.yml`.

The board is now **fully onboarded**. It will participate in the provisioning lifecycle
below indefinitely without further bootloader work.

### Phase 2 — Provisioning lifecycle (repeatable)

Once a board is onboarded, two playbooks drive everything:

#### 2.1 Reprovision a board (Playbook 5 — typical case)

```bash
ansible-playbook playbooks/reprovision.yml --limit rock-5b-01
```

Internally:

1. Sets `dhcp-option=armbian-reprovision` on the board's RouterOS lease and writes
   the per-host `pxelinux.cfg/01-<mac>` for `rw` rootfs mount.
2. Reboots the board over SSH. U-Boot DHCPs, gets next-server, PXE-boots into the
   NFS rootfs read-write.
3. Waits for SSH on the NFS-booted system (auths as `root` / `armbian_default_password`).
4. Asserts the board is actually on NFS, then downloads the `.img.xz` from the netboot
   server's HTTP assets to `/tmp` on the board and `xz | dd`s it to `flash_target_device`.
   Refuses to flash a removable device unless `primary_storage=sd`.
5. Clears the RouterOS DHCP option, reboots the board.
6. Asserts the board comes back up on the freshly flashed disk (rootfs is no longer NFS).

You can run this against multiple boards in parallel with `--limit` selectors:

```bash
ansible-playbook playbooks/reprovision.yml --limit "rock-5b-01,rock-5b-02"
```

#### 2.2 Boot a board into NFS root for testing/maintenance

```bash
ansible-playbook playbooks/enable_netboot.yml \
  --limit rock-5b-01 -e netboot_mode=nfsroot
```

The board boots a read-only NFS rootfs and stays there until you `disable_netboot`.
Useful for diagnostics, kernel testing, or running a board completely diskless.

```bash
# Same, but don't reboot immediately — board picks it up on next reboot.
ansible-playbook playbooks/enable_netboot.yml \
  --limit rock-5b-01 -e netboot_mode=nfsroot -e netboot_reboot=false
```

#### 2.3 Revert a board to disk boot

```bash
ansible-playbook playbooks/disable_netboot.yml --limit rock-5b-01
```

Clears the RouterOS DHCP option for that board. The next reboot lands on disk.

#### 2.4 Power-cycle a board via PoE

When a board is wedged or unreachable over SSH, cycle its upstream RouterOS PoE
switch port instead of pulling cables:

```bash
# Hard power-cycle (off → wait poe_cycle_delay seconds → on)
ansible-playbook playbooks/poe_control.yml --limit rock-5b-01 -e poe_action=cycle

# Power off / on individually
ansible-playbook playbooks/poe_control.yml --limit rock-5b-01 -e poe_action=off
ansible-playbook playbooks/poe_control.yml --limit rock-5b-01 -e poe_action=on

# Bulk: power off the whole lab
ansible-playbook playbooks/poe_control.yml --limit boards -e poe_action=off
```

Each PoE-powered board needs `poe_switch` (inventory hostname of the RouterOS
switch supplying power) and `poe_port` (interface name on that switch, e.g.
`ether3`) set in inventory. The play targets `boards` with `gather_facts: false`
(boards may be powered off) and delegates the `/interface ethernet poe set`
command to each board's switch via `delegate_to: "{{ poe_switch }}"`. Boards on
different switches in the same run are routed correctly without filtering.

Use `-e poe_cycle_delay=<seconds>` to override the off→on dwell (default 5s).

---

## Quick reference

| # | Playbook | Frequency |
|---|---|---|
| 1 | `bootstrap_routeros_user.yml -e ansible_user=<existing-admin>` | Once per RouterOS device |
| 2 | `populate_nfs_content.yml` | Once per environment + on every inventory change |
| 3 | `setup_routeros_dhcp.yml` | Once per RouterOS device |
| 4 | `flash_bootloader.yml --limit <host>` | Once per physical board |
| 5 | `reprovision.yml --limit <host>` | Repeated per refresh |
| — | `enable_netboot.yml --limit <host> -e netboot_mode=nfsroot` | Ad-hoc diskless boot |
| — | `disable_netboot.yml --limit <host>` | Ad-hoc revert to disk |
| — | `poe_control.yml --limit <host> -e poe_action=cycle` | Ad-hoc PoE power-cycle (`on`/`off`/`cycle`) |
| — | `test_hardware_e2e.yml --limit <host>` | Ad-hoc PXE-first hardware E2E test (`-e leave_state=true` to preserve failure state; `-e capture_serial=true` to capture USB-UART serial console to `/tmp/serial-<host>.log`) |

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
- [Board bootloader reference](docs/board-bootloader.md)
- [RouterOS setup guide](docs/routeros-setup.md)

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
