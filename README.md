# david_igou.armbian_netboot

![Galaxy Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgalaxy.ansible.com%2Fapi%2Fv3%2Fplugin%2Fansible%2Fcontent%2Fpublished%2Fcollections%2Findex%2Fdavid_igou%2Farmbian_netboot%2F&query=%24.highest_version.version&label=galaxy)
![Ansible](https://img.shields.io/badge/ansible-%3E%3D2.15-blue?logo=ansible)
![CI](https://img.shields.io/github/actions/workflow/status/david-igou/ansible-collection-armbian_netboot/tests.yml?branch=main&label=CI)
![License](https://img.shields.io/github/license/david-igou/ansible-collection-armbian_netboot)
![Last Commit](https://img.shields.io/github/last-commit/david-igou/ansible-collection-armbian_netboot)

Ansible collection for PXE-netbooting and reprovisioning Armbian-based RK3588/RK3588S
single-board computers. A RouterOS DHCP change is the sole trigger for switching a board
between disk boot and netboot. The netboot server (netboot.xyz + NFS) is assumed to already
be running; this collection manages its NFS export contents and RouterOS DHCP configuration.

**Supported boards:** Orange Pi 5, Orange Pi 5 Pro, Orange Pi 5 Max, Rock 5B, Rock 5A

## Requirements

- Ansible >= 2.15
- A running netboot.xyz instance with NFS exports accessible from the Ansible control node
- A MikroTik RouterOS device with the REST API and DHCP server configured

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
| [`bootloader`](roles/bootloader/) | Flashes PXE-capable U-Boot to SPI or eMMC on boards running Armbian |
| [`nfs_content`](roles/nfs_content/) | Populates NFS exports with Armbian rootfs, kernel, DTB, and image assets |
| [`reprovision`](roles/reprovision/) | Downloads and flashes an Armbian image to disk from within an NFS root environment |
| [`routeros_dhcp`](roles/routeros_dhcp/) | Creates and manages RouterOS DHCP option objects for PXE boot control |

### Playbooks

| Playbook | Description |
|---|---|
| `setup_netboot.yml` | Populate NFS exports and create RouterOS DHCP objects (run once) |
| `flash_bootloader.yml` | Flash U-Boot to SPI or eMMC on boards already running Armbian |
| `prepare_sd_card.yml` | Write U-Boot to an SD card for non-SPI boards |
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

## Quick start

### 1. Configure inventory

Edit `inventory/hosts.yml` to match your network. Each board needs `board_mac` and
`board_model` set; the `board_model` value must match a key in `roles/bootloader/vars/boards.yml`.

### 2. Set variables

Edit `inventory/group_vars/all.yml`:

```yaml
netboot_server_ip: "192.168.1.10"
routeros_host: "192.168.1.1"
routeros_api_password: "changeme"     # encrypt with ansible-vault
armbian_default_password: "1234"      # encrypt with ansible-vault

armbian_image_urls:
  orange-pi-5: "https://dl.armbian.com/orangepi5/Armbian_25.x_..."
  rock-5b:     "https://dl.armbian.com/rock-5b/Armbian_25.x_..."
```

### 3. Initial setup

```bash
ansible-playbook playbooks/setup_netboot.yml
```

### 4. Flash bootloader (one-time per board)

```bash
# SPI-capable boards (OPi5, OPi5 Pro, OPi5 Max, Rock 5B)
ansible-playbook playbooks/flash_bootloader.yml --limit rock-5b-01

# Non-SPI boards: prepare an SD card to insert into the board
ansible-playbook playbooks/prepare_sd_card.yml \
  -e board_model=rock-5a -e sd_card_device=/dev/sdb
```

### 5. Reprovision a board

```bash
ansible-playbook playbooks/reprovision.yml --limit rock-5b-01
```

## Usage examples

```bash
# Enable NFS root (diskless mode) for testing
ansible-playbook playbooks/enable_netboot.yml \
  --limit rock-5b-01 -e netboot_mode=nfsroot

# Enable reprovision mode without rebooting immediately
ansible-playbook playbooks/enable_netboot.yml \
  --limit orange-pi-5-01 -e netboot_mode=reprovision -e netboot_reboot=false

# Revert a board to disk boot
ansible-playbook playbooks/disable_netboot.yml --limit rock-5b-01

# Reprovision multiple boards of the same model in parallel
ansible-playbook playbooks/reprovision.yml --limit "rock-5b-01,rock-5b-02"
```

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
