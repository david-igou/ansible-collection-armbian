# rootfs_provision

## Purpose

Provision a per-host NFS rootfs from an `.img.xz` source. Downloads or
copies an Armbian `.img.xz`, extracts the rootfs into a per-host directory
on the netboot server, stages kernel/initrd/dtb to a TFTP cache directory,
and resets host identity (hostname, machine-id, SSH host keys).

Replaces the two-step `image_extract` + `rootfs_clone` workflow with a
single role invocation. With per-host builds each host may have a unique
image, so extract-and-provision happens in one shot; there is no shared
rootfs-template cross-contamination across hosts.

Runs on the **netboot server** (the host that exports NFS rootfs). The
caller supplies `armbian_rootfs_src`, `armbian_rootfs_host`, and
`armbian_rootfs_dtb`; everything else has defaults.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml) for the full contract.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `armbian_rootfs_src` | yes | — | `.img.xz` source: `https://` URL, `http://` URL, or absolute path on the netboot server. |
| `armbian_rootfs_host` | yes | — | `inventory_hostname` this rootfs is for. Drives identity reset and the target directory suffix. |
| `armbian_rootfs_dtb` | yes | — | DTB path under `/boot/dtb/` to stage as the TFTP `board.dtb` (e.g. `rockchip/rk3588-rock-5b.dtb`). |
| `armbian_rootfs_target_dir` | no | `{{ armbian_nfs_rootfs_path }}/{{ armbian_rootfs_host }}` | NFS rootfs destination directory. |
| `armbian_rootfs_tftp_dir` | no | `{{ armbian_image_cache }}/sbc-tftp/{{ armbian_rootfs_host }}` | Per-host TFTP staging directory. |
| `armbian_rootfs_image_cache` | no | `{{ armbian_image_cache }}/downloads` | URL-keyed shared download cache. Hosts pointing at the same URL share the `.img.xz` download. |
| `armbian_rootfs_force_refresh` | no | `false` | Force re-extract regardless of sentinel. |

## Outputs / side effects

After a successful run:

- `<armbian_rootfs_target_dir>/` is populated with the extracted rootfs.
  Machine-id is zeroed, SSH host keys are regenerated, and `/etc/hostname`
  is updated to `armbian_rootfs_host`.
- `<armbian_rootfs_tftp_dir>/vmlinuz`, `initrd.img`, and `board.dtb` are
  staged and ready for `stage_router.yml` to push to the TFTP server.
- `<armbian_rootfs_target_dir>/.armbian_rootfs_provision_complete` sentinel
  JSON is written; subsequent invocations with the same `src` + `host` skip
  the full provision.
- `<armbian_rootfs_image_cache>/<url-hash>/` holds the cached `.img.xz`;
  shared across all hosts that reference the same URL, so only one download
  occurs per unique URL per run.

## Idempotency & check mode

**Sentinel-based skip.** The role writes a JSON sentinel at
`<armbian_rootfs_target_dir>/.armbian_rootfs_provision_complete` on success.
On subsequent runs it skips the full provision if the sentinel's `src` and
`host` fields match the current inputs. Force a re-extract with
`armbian_rootfs_force_refresh: true` (or `-e armbian_rootfs_force_refresh=true`
on the command line).

**Not check-mode safe.** The extraction pipeline uses `losetup`, `mount`,
and `dd` — these require real kernel interaction and will fail under
`--check`. Do not run this role with `--check`; the sentinel check runs
cleanly but any host that needs extraction will fail at the loop-device step.

## Rollback

If a provision fails mid-extract, the `always:` cleanup block in `main.yml`
detaches loop devices and unmounts any in-progress mount. The
`<armbian_rootfs_target_dir>` may be partially populated. To recover:

1. Manually `rm -rf <armbian_rootfs_target_dir>` on the netboot server.
2. Re-run with `armbian_rootfs_force_refresh: true` to bypass any stale
   sentinel and start fresh.

## Example

```yaml
- name: Provision per-host NFS rootfs on the netboot server
  hosts: netboot_server
  become: true
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian.rootfs_provision
      vars:
        armbian_rootfs_src:    "{{ hostvars[item].armbian_rootfs_src }}"
        armbian_rootfs_host:   "{{ item }}"
        armbian_rootfs_dtb:    "{{ hostvars[item].armbian_board_config.dtb }}"
      loop: "{{ groups['boards'] }}"
```

Typically reached via `playbooks/stage_netboot_assets.yml`.
