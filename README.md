# david_igou.armbian_netboot

![Galaxy Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgalaxy.ansible.com%2Fapi%2Fv3%2Fplugin%2Fansible%2Fcontent%2Fpublished%2Fcollections%2Findex%2Fdavid_igou%2Farmbian_netboot%2F&query=%24.highest_version.version&label=galaxy)
![Ansible](https://img.shields.io/badge/ansible-%3E%3D2.15-blue?logo=ansible)
![CI](https://img.shields.io/github/actions/workflow/status/david-igou/ansible-collection-armbian_netboot/tests.yml?branch=main&label=CI)
![License](https://img.shields.io/github/license/david-igou/ansible-collection-armbian_netboot)
![Last Commit](https://img.shields.io/github/last-commit/david-igou/ansible-collection-armbian_netboot)

Ansible collection for PXE-netbooting and reprovisioning Armbian-based ARM single-board
computers. A RouterOS DHCP change is the sole trigger for switching a board between disk
boot and netboot. The netboot server (netboot.xyz + NFS) is assumed to already be running;
this collection manages its NFS export contents and RouterOS DHCP configuration.

The bootloader role is structured around per-SoC-family strategies; current implementations
cover Rockchip (RK3588/RK3588S/RK3399/RK356x via Armbian's unified U-Boot format) and
Allwinner (sunxi). Additional families add a SoC vars file under
`roles/bootloader/vars/socs/` plus, if the eMMC layout differs, a per-strategy task file.

**Sample inventory boards:** Orange Pi 5, Orange Pi 5 Pro, Orange Pi 5 Max, Rock 5B,
Rock 5A (Rockchip); Orange Pi Zero 3 (Allwinner).

## Requirements

- Ansible >= 2.15
- A running netboot.xyz instance with NFS exports accessible from the Ansible control node
- A MikroTik RouterOS device with SSH access and a DHCP server configured

### Collection dependencies

| Collection | Version |
|---|---|
| `community.routeros` | >= 2.0.0 |
| `ansible.posix` | >= 1.5.0 |
| `ansible.netcommon` | >= 5.0.0 |

## Included content

### Roles

| Role | Description |
|---|---|
| [`bootloader`](roles/bootloader/) | Flashes PXE-capable U-Boot to SPI / eMMC / SD on boards running Armbian |
| [`bootstrap_routeros_user`](roles/bootstrap_routeros_user/) | Idempotently provisions a RouterOS user, group, and SSH keys over network_cli |
| [`nfs_content`](roles/nfs_content/) | Populates NFS exports with Armbian rootfs, kernel, DTB, and image assets |
| [`reprovision`](roles/reprovision/) | Downloads and flashes an Armbian image to disk from within an NFS root environment |
| [`routeros_dhcp`](roles/routeros_dhcp/) | Creates and manages RouterOS DHCP option objects for PXE boot control |

### Playbooks

| Playbook | Description |
|---|---|
| `bootstrap_routeros_user.yml` | One-time: provision the RouterOS user and SSH keys this collection uses |
| `setup_netboot.yml` | One-time: populate NFS exports and create RouterOS DHCP objects |
| `flash_bootloader.yml` | One-time per board: flash PXE-first U-Boot to SPI / eMMC / SD |
| `enable_netboot.yml` | Enable PXE boot for boards (`nfsroot` or `reprovision` mode) |
| `disable_netboot.yml` | Revert boards to local disk boot |
| `reprovision.yml` | Full Ansible-driven flash workflow: PXE boot → flash → disk boot |

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
it only needs to happen once.

### Phase 0 — One-time control-plane setup

Done once per environment, before adding any boards.

#### 0.1 Configure global variables

Edit `inventory/group_vars/all.yml`:

```yaml
netboot_server_ip: "192.168.1.10"     # host running netboot.xyz + NFS
routeros_host: "192.168.1.1"          # RouterOS device IP
routeros_ssh_user: "ansible-netboot"  # provisioned by bootstrap_routeros_user.yml
routeros_ssh_port: 22                 # RouterOS SSH port
armbian_apt_suite: "bookworm"         # Armbian apt suite for preflight package validation
armbian_default_password: "1234"      # encrypt with ansible-vault before committing
```

The netboot server is **assumed to already be running** (netboot.xyz container + NFS
exports). The collection populates content into the existing exports — it does not stand
up the server itself. The export root paths (`nfs_rootfs_path`, `tftp_nfs_export`,
`nfs_assets_export`) must already exist and be exported read/write.

#### 0.2 Provision the RouterOS user

Run once against your RouterOS device using an existing admin account:

```bash
ansible-playbook playbooks/bootstrap_routeros_user.yml
```

This idempotently creates the `ansible-netboot` user, an `ansible` group with the
permissions the collection needs, and installs the SSH key the control node uses. From
this point on every other playbook authenticates as that user over SSH (no API/REST).

#### 0.3 Populate NFS exports and create RouterOS DHCP objects

Once your `boards` group has at least one host and the corresponding `armbian_image_urls`
entry, run:

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/setup_netboot.yml
```

This:

- Pre-flights every board's `uboot_apt_package` against the Armbian apt repo and HEAD-checks
  every `armbian_image_urls` entry. Misconfigurations fail here, before any destructive work.
- For each unique board model in inventory, downloads its Armbian image, extracts the
  rootfs into `nfs_rootfs_path/_templates/<model>/`, and stages kernel/initrd/DTB into
  the TFTP tree.
- For each inventory host, reflink-clones the model template into
  `nfs_rootfs_path/<inventory_hostname>/` and resets hostname / machine-id / SSH host
  keys so the host has independent identity on the wire.
- Creates the shared RouterOS `dhcp-option` and option-set objects (`armbian-nfsroot`,
  `armbian-reprovision`) that per-board `enable_netboot` runs reuse.

Re-run `setup_netboot.yml` whenever you add a new board model, change an image URL, or
add a new host to inventory. It is idempotent.

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

#### 1.4 Add the image URL

Edit `inventory/group_vars/all.yml`:

```yaml
armbian_image_urls:
  rock-5b: "https://dl.armbian.com/rock-5b/Armbian_..."
```

Pin the full versioned URL or an Armbian-published alias (e.g.
`Noble_current_minimal`). Pre-flight in `setup_netboot.yml` HEAD-checks this URL.

#### 1.5 Re-run setup_netboot.yml

```bash
ansible-playbook playbooks/setup_netboot.yml
```

This builds the NFS rootfs and TFTP staging for the new board model (if new) and creates
the per-host rootfs clone for this specific host. Existing boards are unaffected (the
extraction step is skipped if the model template is already populated).

#### 1.6 Flash PXE-first U-Boot to the board

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
  SoC family's `sd_uboot_seek_sectors` offset (Rockchip 64, Allwinner 16). Sets PXE-first
  `boot_targets` via `fw_setenv` on the board's own `/etc/fw_env.config`. Hard-fails if
  the rootfs is not on a removable SD card.

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

#### 2.1 Reprovision a board (typical case)

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

---

## Quick reference

| Phase | Playbook | Frequency |
|---|---|---|
| Provision RouterOS user | `bootstrap_routeros_user.yml` | Once per environment |
| Populate NFS + DHCP objects | `setup_netboot.yml` | Once per environment, then on every inventory change |
| Flash PXE U-Boot | `flash_bootloader.yml --limit <host>` | Once per physical board |
| Reprovision (PXE → flash → disk) | `reprovision.yml --limit <host>` | Repeated per refresh |
| Enable diskless NFS boot | `enable_netboot.yml --limit <host> -e netboot_mode=nfsroot` | Ad-hoc |
| Revert to disk boot | `disable_netboot.yml --limit <host>` | Ad-hoc |

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
