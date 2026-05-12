# netboot_assets

Populates two locations with everything an Armbian board needs to PXE-boot
into an NFS rootfs:

- **Netboot server (e.g. TrueNAS) over SSH**: per-model rootfs template
  extracted from the Armbian `.img.xz` into
  `nfs_rootfs_path/_templates/<board_model>/`, plus per-host rootfs clones
  at `nfs_rootfs_path/<inventory_hostname>/` (reflink-cloned from the
  model template — zero-cost on XFS/btrfs/ZFS, full copy on ext4 — with
  hostname/machine-id/SSH host keys reset for unique on-the-wire
  identity). Pre-flight HEAD-checks each `armbian_image_urls` entry before
  any destructive work begins.
- **rb5009 over network_cli**: per-model `vmlinuz`, `initrd.img`, and
  `board.dtb` `net_put` to `flash:/<sbc_tftp_flash_dir>/armbian/<model>/`,
  with a corresponding `/ip tftp` row per file. Files are first fetched
  from the netboot server to a control-node cache (`sbc_tftp_cache_dir`)
  and then uploaded to rb5009 — no direct TrueNAS↔rb5009 path.

The netboot-server play runs as root over SSH (loop-mounts an ext4
filesystem) and operates on the export paths directly. It does not mount
NFS on the Ansible control node, so the control node needs no NFS client
and the role is compatible with rootless execution environments
(ansible-navigator + rootless podman).

The NFS export paths must already exist on the netboot server and be
exported read/write to the boards. The role only writes content into them.

Required tools on the netboot server: `losetup`, `mount`, `xz`, `rsync`,
`lsblk` (all standard on TrueNAS SCALE / Debian-based hosts).

## Role variables

| Variable | Default | Description |
|---|---|---|
| `nfs_rootfs_path` | `/mnt/ssd/netboot/rootfs` | NFS export root for per-board rootfs trees on the netboot server. |
| `nfs_assets_export` | `/mnt/ssd/public/boot-files` | Netboot-owned subtree on the HTTP host. Images are published at `{{ nfs_assets_export }}/images/<armbian_board_name>/<basename>` and looked up by the role at the same path; URL prefix and FS layout don't need to match. Default matches the homelab public nginx container on TrueNAS (URL prefix `https://public.igou.systems/boot-files/`). |
| `armbian_image_cache` | `/mnt/ssd/netboot/cache` | Local cache for downloaded `.img.xz` files on the netboot server. |
| `armbian_image_mount` | `/mnt/ssd/netboot/.loop-mount` | Temporary loop-mount point on the netboot server while extracting an image. |
| `sbc_tftp_flash_dir` | `sbc` | Top-level directory on rb5009's flash for SBC TFTP content. Used as the `name=` prefix in `/file` paths and as the `real-filename` prefix in `/ip tftp` rules. Mirrored as a default in `roles/routeros_dhcp/defaults/main.yml`. |
| `sbc_tftp_cache_dir` | `{{ playbook_dir }}/../.cache/sbc-tftp` | Control-node cache where kernel/initrd/dtb fetched from the netboot server are stashed before `net_put` to rb5009. Resolved relative to the playbook directory; lands at `<repo-root>/.cache/sbc-tftp/<model>/`. Gitignored. |

`netboot_server_ip` and the per-model entries in `armbian_image_urls` must
be set in inventory (typically `inventory/group_vars/all.yml`).

## Example

The role is normally invoked from `playbooks/stage_netboot_assets.yml`,
which runs the default entry-point against the netboot server (NFS
rootfs + control-node cache fetch) and then includes
`tasks_from: stage_rb5009.yml` against rb5009 to upload the per-model
TFTP content. To call the netboot-server half directly:

```yaml
- name: Stage NFS rootfs on the netboot server
  hosts: netboot_server
  become: true
  gather_facts: false
  roles:
    - role: david_igou.armbian_netboot.netboot_assets
```

To call the rb5009 half directly (after the cache has been populated):

```yaml
- name: Stage per-model TFTP assets on rb5009
  hosts: routeros_routers
  gather_facts: false
  tasks:
    - name: Push kernel/initrd/dtb + register /ip tftp rows
      ansible.builtin.include_role:
        name: david_igou.armbian_netboot.netboot_assets
        tasks_from: stage_rb5009.yml
```

## License

GPL-3.0-or-later
