# nfs_content

Populates the netboot server's NFS exports with everything needed for an
Armbian board to PXE-boot:

- Pre-flight: validates each board's `uboot_apt_package` exists in the
  Armbian apt repo and HEAD-checks each `armbian_image_urls` entry before
  any destructive work begins.
- Per-board rootfs template extracted from the Armbian `.img.xz` into
  `nfs_rootfs_path/_templates/<board_model>/`.
- Per-host rootfs clone: every inventory host gets its own
  `nfs_rootfs_path/<inventory_hostname>/` directory, reflink-cloned from
  the model template (zero-cost on XFS/btrfs/ZFS, full copy on ext4),
  with hostname/machine-id/SSH host keys reset for unique on-the-wire
  identity.
- Kernel, DTB, and initrd staged for TFTP (per-model; shared by all
  hosts of that model).
- A copy of each `.img.xz` published to the netboot HTTP assets directory
  so the `reprovision` role can fetch it from inside the NFS-booted
  environment.

The role runs **on the netboot server itself** (e.g. a TrueNAS host) over
SSH and operates on the export paths directly. It does not mount NFS on the
Ansible control node, so the control node needs no NFS client, no root, and
the role is compatible with rootless execution environments
(ansible-navigator + rootless podman).

The export paths must already exist on the netboot server and be exported
read/write to the boards. The role only writes content into them.

Required tools on the netboot server: `losetup`, `mount`, `xz`, `rsync`,
`lsblk` (all standard on TrueNAS SCALE / Debian-based hosts). Image
extraction loop-mounts an ext4 filesystem, which requires root on the
netboot server (`become: true`).

## Role variables

| Variable | Default | Description |
|---|---|---|
| `nfs_rootfs_path` | `/exports/rootfs` | NFS export root for per-board rootfs trees on the netboot server. |
| `nfs_reprovision_path` | `/exports/reprovision` | NFS export path used by the reprovision flow. |
| `tftp_nfs_export` | `/opt/netbootxyz/config` | TFTP config root on the netboot server (where pxelinux.cfg + per-board kernel/DTB/initrd live). |
| `nfs_assets_export` | `/opt/netbootxyz/assets` | netboot.xyz HTTP assets root on the netboot server. |
| `armbian_image_cache` | `/var/cache/armbian-images` | Local cache for downloaded `.img.xz` files on the netboot server. On TrueNAS, override to a path on a data pool — the boot pool is small. |
| `armbian_image_mount` | `/mnt/armbian-image` | Temporary loop-mount point on the netboot server while extracting an image. |

`netboot_server_ip` and the per-model entries in `armbian_image_urls` must
be set in inventory (typically `inventory/group_vars/all.yml`).

## Example

```yaml
- name: Populate NFS exports
  hosts: netboot_server
  become: true
  gather_facts: false
  roles:
    - role: david_igou.armbian_netboot.nfs_content
```

## License

GPL-3.0-or-later
