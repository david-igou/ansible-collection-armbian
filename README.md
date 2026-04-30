# david_igou.armbian_netboot

Ansible collection for PXE-netbooting and reprovisioning Armbian-based RK3588/RK3588S
single-board computers. A RouterOS DHCP change is the sole trigger for switching a board
between disk boot and netboot. The netboot server (netboot.xyz + NFS) is assumed to already
be running; this collection manages its NFS export contents and RouterOS DHCP configuration.

**Supported boards:** Orange Pi 5, Orange Pi 5 Pro, Orange Pi 5 Max, Rock 5B, Rock 5A

## Requirements

- Ansible ≥ 2.15
- A running netboot.xyz instance with NFS exports accessible from the Ansible control node
- A MikroTik RouterOS device with the REST API and DHCP server configured
- `ansible.posix`, `community.routeros`, and `ansible.netcommon` collections (see below)

## Installation

```bash
ansible-galaxy collection install david_igou.armbian_netboot
```

Or clone this repository and install dependencies directly:

```bash
git clone https://github.com/david-igou/armbian-netboot-reprovision
cd armbian-netboot-reprovision
ansible-galaxy collection install -r requirements.yml
```

## Included Content

### Roles

| Role | Description |
|---|---|
| `bootloader` | Flashes PXE-capable U-Boot to SPI or eMMC on boards running Armbian |
| `nfs_content` | Populates NFS exports with Armbian rootfs, kernel, DTB, and image assets |
| `reprovision` | Downloads and flashes an Armbian image to disk from within an NFS root environment |
| `routeros_dhcp` | Creates and manages RouterOS DHCP option objects for PXE boot control |

### Playbooks

| Playbook | Description |
|---|---|
| `setup_netboot.yml` | Populate NFS exports and create RouterOS DHCP objects (run once) |
| `flash_bootloader.yml` | Flash U-Boot to SPI or eMMC on boards already running Armbian |
| `prepare_sd_card.yml` | Write U-Boot to an SD card for non-SPI boards |
| `enable_netboot.yml` | Enable PXE boot for boards (`nfsroot` or `reprovision` mode) |
| `disable_netboot.yml` | Revert boards to local disk boot |
| `reprovision.yml` | Full Ansible-driven flash workflow: PXE boot → flash → disk boot |

## Quick Start

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
  # ... one URL per board model in inventory
```

### 3. Initial setup

```bash
# Populate NFS exports and create RouterOS DHCP objects
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

## Usage Examples

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
ansible-playbook playbooks/reprovision.yml \
  --limit "rock-5b-01,rock-5b-02"
```

## Collection Structure

```
david_igou/armbian_netboot/
├── galaxy.yml                        # Collection metadata
├── ansible.cfg                       # Ansible config for direct use
├── requirements.yml                  # External collection dependencies
├── meta/
│   └── runtime.yml                   # Minimum Ansible version
├── roles/
│   ├── bootloader/                   # U-Boot flashing (SPI/eMMC) + SD card prep
│   ├── nfs_content/                  # Populate NFS exports from Armbian images
│   ├── reprovision/                  # Flash Armbian image to disk
│   └── routeros_dhcp/                # RouterOS DHCP option management
├── playbooks/
│   ├── setup_netboot.yml
│   ├── flash_bootloader.yml
│   ├── prepare_sd_card.yml
│   ├── enable_netboot.yml
│   ├── disable_netboot.yml
│   └── reprovision.yml
├── inventory/                        # Example inventory (customise for your lab)
│   ├── hosts.yml
│   └── group_vars/
│       ├── all.yml
│       ├── rk3588.yml
│       └── routeros.yml
└── docs/
    ├── architecture.md
    ├── board-bootloader.md
    └── routeros-setup.md
```

## Documentation

- [Architecture and boot flow](docs/architecture.md)
- [Board bootloader reference](docs/board-bootloader.md)
- [RouterOS setup guide](docs/routeros-setup.md)

## Dependencies

Install with `ansible-galaxy collection install -r requirements.yml`:

| Collection | Version | Purpose |
|---|---|---|
| `community.routeros` | ≥ 2.0.0 | RouterOS API/command modules |
| `ansible.posix` | ≥ 1.5.0 | NFS mount module |
| `ansible.netcommon` | ≥ 5.0.0 | `httpapi` connection plugin for RouterOS |

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
