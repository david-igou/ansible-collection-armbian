# image_extract

## Purpose

Extract one Armbian `.img.xz` into a per-model rootfs template and the
per-model TFTP artefacts (vmlinuz / initrd / DTB). Decompresses the
image, loop-mounts it, rsyncs the rootfs partition into `template_dir`,
and copies `vmlinuz` / `initrd.img` / the named DTB into `tftp_dir`.

The `.img.xz` source can be a local filesystem path on this host
(already published by an upstream build/publish step) or an
`http(s)://` URL the role downloads. Runs on a single host with sudo
plus `losetup` — typically the netboot server. The role knows nothing
about NFS, HTTP, or TFTP; the caller is responsible for placing
`template_dir` and `tftp_dir` where the downstream playbooks
(`rootfs_clone`, `stage_router.yml`) can read them.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml). Summary:

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `armbian_image_src` | yes | — | Local filesystem path OR `http(s)://` URL to the `.img.xz`. |
| `model_name` | yes | — | Identifier used in the image cache filename — typically the board model. |
| `template_dir` | yes | — | Destination directory for the extracted rootfs template. |
| `tftp_dir` | yes | — | Destination directory for `vmlinuz` / `initrd.img` / `board.dtb`. |
| `board_dtb` | yes | — | Basename of the DTB to copy from the image's `/boot` tree (e.g. `rk3588s-orangepi-5-pro.dtb`). |
| `force_refresh` | no | `false` | When true, remove `template_dir`, `tftp_dir`, and the cached image before re-extracting. |
| `image_cache_dir` | no | `/var/lib/armbian/cache` | Scratch directory for downloads and the decompressed `.img`. |
| `image_mount_dir` | no | `/var/lib/armbian/mnt` | Mount point used during extraction. |

## Outputs / side effects

After a successful run:

- `template_dir` contains a full Armbian rootfs (copied from the
  rootfs partition of the source `.img`).
- `tftp_dir` contains exactly three files: `vmlinuz`, `initrd.img`,
  and the DTB named by `board_dtb`.
- `image_cache_dir` retains the decompressed `.img` and (when the
  source was a URL) the downloaded `.img.xz`.
- `image_mount_dir` exists but is unmounted by the role's `always`
  block.
- A sentinel file `.armbian_extract_complete` is written inside
  `template_dir` at the end of the success path (consumed by the
  role's own idempotency probe on subsequent runs — landing in
  [WS-4 of the best-practices fixes pass](../../docs/superpowers/specs/2026-05-20-best-practices-fixes-design.md)).

## Idempotency & check mode

- The role detects a previous successful extraction by probing for the
  sentinel file under `template_dir` and skips re-extracting when it
  finds one.
- `force_refresh: true` removes `template_dir` + `tftp_dir` + the
  cached image before re-extracting.
- Loop-mount / unmount happens inside a `block` / `rescue` / `always`
  lifecycle so leaked loop devices on failure are torn down.
- `--check` mode is not meaningfully supported — the role's mutation
  is gated on a single binary signal (sentinel present / absent), so
  in check mode the role either reports "would extract" or "would
  skip" with no finer-grained dry-run.

## Example

```yaml
- name: Stage netboot rootfs templates and TFTP assets
  hosts: netboot_server
  become: true
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian.image_extract
      vars:
        armbian_image_src: "{{ armbian_image_urls['orange-pi-5-pro'] }}"
        model_name: orange-pi-5-pro
        template_dir: "{{ armbian_nfs_rootfs_path }}/_templates/orange-pi-5-pro"
        tftp_dir: "{{ armbian_nfs_assets_export }}/tftp/armbian/orange-pi-5-pro"
        board_dtb: rk3588s-orangepi-5-pro.dtb
```
