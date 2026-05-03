# nfs_content

Populates the netboot server's NFS exports with everything needed for an
Armbian board to PXE-boot:

- Per-board rootfs extracted from the Armbian `.img.xz`
- Kernel, DTB, and initrd staged for TFTP
- A copy of each `.img.xz` published to the netboot HTTP assets directory so
  the `reprovision` role can fetch it from inside the NFS-booted environment

All file operations happen on the Ansible control node by mounting the
netboot server's exports locally — no SSH access to the netboot server is
required.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `nfs_local_mount` | `/mnt/netboot` | Base path used for local NFS mounts. |
| `armbian_image_mount` | `/mnt/armbian-image` | Loop-mount point for extracting an Armbian image. |
| `armbian_image_cache` | `/var/cache/armbian-images` | Local cache for downloaded `.img.xz` files. |
| `nfs_rootfs_path` | `/exports/rootfs` | NFS export path on the netboot server for board rootfs. |
| `nfs_reprovision_path` | `/exports/reprovision` | NFS export path used by the reprovision flow. |
| `tftp_nfs_export` | `/opt/netbootxyz/config` | Path to the netboot.xyz TFTP config export. |
| `nfs_assets_export` | `/opt/netbootxyz/assets` | Path to the netboot.xyz HTTP assets export. |
| `tftp_base` | `{{ nfs_local_mount }}/tftp` | Local mount of the TFTP config export. |

`netboot_server_ip` and the per-model entries in `armbian_image_urls` must be
set elsewhere (typically in `inventory/group_vars/all.yml`).

## Example

```yaml
- name: Populate NFS exports
  hosts: localhost
  roles:
    - role: david_igou.armbian_netboot.nfs_content
```

## License

GPL-3.0-or-later
