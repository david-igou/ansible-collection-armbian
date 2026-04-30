# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Ansible automation for PXE-netbooting and reprovisioning Armbian-based RK3588/RK3588S SBCs (Orange Pi 5/Pro/Max, Rock 5B, Rock 5A). A RouterOS DHCP change is the sole trigger for switching a board between disk boot and netboot. The netboot server (running netboot.xyz + NFS) is assumed to already be running; this repo only manages its NFS export contents and RouterOS DHCP configuration.

## Running playbooks

All playbooks live in `ansible/playbooks/`. Run them from the `ansible/` directory (where `ansible.cfg` is):

```bash
cd ansible

# Install required collections first
ansible-galaxy collection install -r requirements.yml

# Populate NFS exports with rootfs/kernel/DTB and configure RouterOS DHCP objects
ansible-playbook playbooks/setup_netboot.yml

# Flash U-Boot to SPI on a specific board (board must already run Armbian)
ansible-playbook playbooks/flash_bootloader.yml --limit rock-5b-01

# Prepare SD card bootloader for a non-SPI board (runs on the Ansible control node)
ansible-playbook playbooks/prepare_sd_card.yml \
  -e board_model=rock-5a -e sd_card_device=/dev/sdb

# Enable netboot (reprovision or nfsroot mode)
ansible-playbook playbooks/enable_netboot.yml \
  --limit rock-5b-01 -e netboot_mode=reprovision

# Full reprovision workflow (stages image, enables PXE, reboots board)
ansible-playbook playbooks/reprovision.yml --limit rock-5b-01

# Manually revert a board to disk boot
ansible-playbook playbooks/disable_netboot.yml --limit rock-5b-01
```

## Required configuration before first run

Set all values in `ansible/inventory/group_vars/all.yml`:

- `netboot_server_ip` — IP of the host running netboot.xyz + NFS
- `routeros_host` — RouterOS device IP
- `routeros_api_password` — use ansible-vault to encrypt this
- `armbian_image_urls` — full `.img.xz` URL per board model, found at `https://dl.armbian.com/<armbian_dl_dir>/`

The NFS exports and paths (`nfs_rootfs_path`, `nfs_reprovision_path`, `tftp_nfs_export`, `nfs_assets_export`) must already exist and be accessible from the Ansible control node before running `setup_netboot.yml`.

Each board in `ansible/inventory/hosts.yml` needs `board_mac` and `board_model` set. The `board_model` value must exactly match a key in `ansible/roles/bootloader/vars/boards.yml`.

## Architecture: two bootloader paths

**The key invariant**: RouterOS DHCP options are the *only* control surface for switching boot mode. U-Boot always tries PXE first and falls through to disk when DHCP provides no `next-server`.

### SPI boards (OPi5, OPi5 Pro, OPi5 Max, Rock 5B)
- `flash_bootloader.yml` SSHes into the board, `apt install`s the Armbian U-Boot package from the Armbian repo, and writes the binary to `/dev/mtd0`
- U-Boot package installs to `/usr/lib/linux-u-boot-current-<board>/` on the board itself
- After flashing, no physical access is ever needed again — DHCP controls everything

### SD card boards (Rock 5A, Rock 5B with unpopulated SPI socket)
- `prepare_sd_card.yml` runs on the **Ansible control node**, using U-Boot binaries cached at `armbian_image_cache/uboot-<model>/` during `setup_netboot.yml`
- Writes U-Boot to the SD card at sector 64 and sets `boot_targets=pxe dhcp mmc0 nvme0 mmc1` in the card's U-Boot environment via `fw_setenv`
- The U-Boot env offset is read from the extracted Armbian rootfs at `nfs_rootfs_path/<model>/etc/fw_env.config` — `setup_netboot.yml` must run before `prepare_sd_card.yml`
- SD card stays inserted permanently; it acts identically to SPI flash

## How NFS content is managed

All file operations on the netboot server go through NFS mounts on the Ansible control node — there is no SSH access to the netboot server required.

- `setup_netboot.yml` mounts the TFTP config export (`tftp_nfs_export`), NFS rootfs export (`nfs_rootfs_path`), NFS reprovision export (`nfs_reprovision_path`), and assets export (`nfs_assets_export`) via `ansible.posix.mount`, writes content through those mounts, then unmounts.
- `enable_netboot.yml` mounts the TFTP config export, writes the per-board `pxelinux.cfg`, then unmounts.
- The `reprovision` role mounts the NFS reprovision export, writes `reprovision.sh` and credentials, then unmounts.

Mount base on the control node: `nfs_local_mount` (default `/mnt/netboot`), with subdirs `tftp/`, `assets/`, `rootfs/`, `reprovision/`.

## Where things run

| Playbook | Runs on |
|---|---|
| `setup_netboot.yml` | Ansible control node (NFS mounts) + RouterOS (DHCP objects) |
| `flash_bootloader.yml` | **boards** (requires Armbian running + internet for apt) |
| `prepare_sd_card.yml` | Ansible control node (SD card attached via USB reader) |
| `enable/disable_netboot.yml` | Ansible control node (pxelinux.cfg via NFS) + RouterOS (DHCP) |
| `reprovision.yml` | Ansible control node (image staging via NFS) + RouterOS (DHCP trigger) |

`reprovision.sh` runs **on the board itself** after it PXE-boots into the NFS reprovision root. It flashes the disk, then calls the RouterOS REST API to clear `dhcp-option` on the board's lease before rebooting.

## Adding a new board

1. Add an entry to `ansible/roles/bootloader/vars/boards.yml` — the key becomes the `board_model` value used everywhere. Fields that differ from other boards: `armbian_dl_dir` (subdirectory at `dl.armbian.com`), `armbian_board_name` (apt package suffix, no dashes), `uboot_package`, `dtb`, `has_spi`.
2. Add hosts to `ansible/inventory/hosts.yml` under the appropriate group with `board_mac` and `board_model`.
3. Add a URL to `armbian_image_urls` in `group_vars/all.yml`.
4. Re-run `setup_netboot.yml` to extract rootfs, kernel, DTB, and U-Boot binaries for the new model.

Note: `armbian_dl_dir` and `armbian_board_name` are distinct — the download directory uses dashes (`orangepi5-pro`) while the apt package name does not (`orangepi5pro`).

## RouterOS DHCP objects

Three object types are created once by `setup_netboot.yml` and reused for all boards:
- Two `dhcp-option` entries for option 66 (TFTP server) and option 67 (boot file) per mode
- Two `dhcp-option` sets (`armbian-nfsroot`, `armbian-reprovision`) that bundle them

Per-board `enable_netboot` sets `dhcp-option=armbian-nfsroot|armbian-reprovision` on the static lease; `disable_netboot` clears it to `""`. This is the only per-board RouterOS state.

## Key files

- `ansible/roles/bootloader/vars/boards.yml` — authoritative hardware config for all board models
- `ansible/inventory/group_vars/all.yml` — IPs, credentials, image URLs (edit before first run)
- `ansible/inventory/group_vars/rk3588.yml` — RK3588 U-Boot env offset defaults (verify against hardware)
- `ansible/roles/reprovision/files/reprovision.sh` — bash script that runs on the board during reprovision; reads kernel cmdline params and `/etc/reprovision.conf` from the NFS export
- `ansible/roles/routeros_dhcp/templates/pxelinux_cfg.j2` — per-board TFTP boot config template; generated by `enable_netboot`
