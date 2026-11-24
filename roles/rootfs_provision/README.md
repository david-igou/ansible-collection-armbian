# rootfs_provision

Provision a per-host NFS rootfs and its TFTP boot files from an Armbian
`.img.xz`. Runs on the host that exports the NFS rootfs.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml) for the full contract.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `rootfs_provision_src` | yes | — | `.img.xz` http(s) URL or absolute path on the host |
| `rootfs_provision_checksum` | no | `""` | `get_url` checksum, e.g. `sha256:https://host/image.img.xz.sha` |
| `rootfs_provision_hostname` | yes | — | Hostname written into the rootfs |
| `rootfs_provision_target_dir` | yes | — | Per-host NFS rootfs directory; its contents are replaced |
| `rootfs_provision_tftp_dir` | yes | — | Per-host TFTP staging directory |
| `rootfs_provision_cache_dir` | yes | — | Download cache, `<cache_dir>/<sha256 of src>/<basename>` |
| `rootfs_provision_dtb` | no | `""` | DTB to stage as `board.dtb`, e.g. `rockchip/rk3588-rock-5b.dtb`; empty stages none |
| `rootfs_provision_mount_dir` | no | `/mnt/rootfs_provision` | Temporary read-only mount of the image |
| `rootfs_provision_force` | no | `false` | Re-extract even when the sentinel matches |

The role sets no facts.

## What it does

1. Validates the inputs (URL or absolute path ending in `.img.xz`;
   absolute directories other than `/`) and refuses a target directory
   that is a mountpoint (it gathers the `mounts` fact subset itself).
2. Fetches the image into the cache on every run. With a checksum,
   `get_url` downloads only on a mismatch; without one it revalidates the
   cached copy (If-Modified-Since for a URL, a content compare for a path).
3. Hashes the cached image and compares `src`, `image_sha256` and
   `hostname` with `<target_dir>/.rootfs_provision.json`. When all three
   match and `rootfs_provision_force` is false, it stops here.
4. Otherwise it decompresses the image, attaches it read-only to a loop
   device, mounts the largest partition (`lsblk --json`) and mirrors it
   into the target with `rsync --delete` (excluding `/proc`, `/sys`, `/dev`
   and `/run` contents). Files in the target that are not in the image are
   removed. The loop device, mount and decompressed copy are always
   cleaned up.
5. Removes `/dev/` lines from the rootfs `/etc/fstab`, stages
   `boot/vmlinuz-*` and `boot/initrd.img-*` (exactly one each) as
   `vmlinuz` and `initrd.img`, and the DTB, if requested, as `board.dtb`.
6. Writes `/etc/hostname` and the `127.0.1.1` line of `/etc/hosts` (when
   the file exists), empties both machine-id files, replaces the SSH host
   keys with fresh rsa, ecdsa and ed25519 keys, creates
   `/root/.no_armbian_first_login`, and writes the sentinel.

## Preconditions

Root on the host (use `become`), and `xz`, `losetup`, `lsblk`, `udevadm`,
`rsync` and `ssh-keygen` installed. Not check-mode safe.

## Example

```yaml
- name: Provision NFS rootfs for the boards
  hosts: netboot_server
  become: true
  gather_facts: false
  tasks:
    - name: Provision one board
      ansible.builtin.include_role:
        name: david_igou.armbian.rootfs_provision
      vars:
        rootfs_provision_src: https://images.example.lan/orange-pi-5-pro-01.img.xz
        rootfs_provision_checksum: sha256:https://images.example.lan/orange-pi-5-pro-01.img.xz.sha
        rootfs_provision_hostname: orange-pi-5-pro-01
        rootfs_provision_dtb: rockchip/rk3588s-orangepi-5-pro.dtb
        rootfs_provision_target_dir: /srv/netboot/rootfs/orange-pi-5-pro-01
        rootfs_provision_tftp_dir: /srv/netboot/tftp/orange-pi-5-pro-01
        rootfs_provision_cache_dir: /var/cache/rootfs_provision
```

## Sentinel

```json
{
  "hostname": "orange-pi-5-pro-01",
  "image_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "provisioned_at": "2026-05-28T12:34:56Z",
  "src": "https://images.example.lan/orange-pi-5-pro-01.img.xz"
}
```

## Recovery

If a run fails mid-extract the target may be partly populated and has no
matching sentinel, so the next run extracts again. `rootfs_provision_force:
true` re-extracts regardless.
