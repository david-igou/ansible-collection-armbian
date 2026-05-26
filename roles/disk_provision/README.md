# disk_provision

## Purpose

Apply a declarative partition layout to one block device and populate it
from a source rootfs. Given one `disk_binding` (device + layout list),
the role validates the layout, renders `systemd-repart` `.repart.d/*.conf`
files, invokes `systemd-repart` against the device, populates each
filesystem by rsyncing `source` (default `/`), writes an `/etc/fstab` on
the root partition referencing every mount by `LABEL=`, and unmounts.

Single-disk contract: callers with multiple disks loop the role per
binding. Transport-agnostic — knows nothing about netboot, PXE, boot
modes, or what the rootfs will be used for. The typical caller is an
NFS-booted board copying its running rootfs onto a local NVMe.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml) for the full
contract. Summary:

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `disk_binding` | yes | — | One entry from `armbian_local_disks`. Shape: `{device, wipe?, force?, fast_wipe?, layout: [...]}`. |
| `source` | no | `/` | Source rootfs to rsync into the populated root partition. |
| `armbian_installed_marker` | no | `true` | Write `INSTALLED=true` to `/etc/armbian-image-release` to suppress `armbian-resize-filesystem`. |
| `reset_identity` | no | `false` | Zero machine-id files on the target. Default false because the typical caller wants the same identity across boot modes. |
| `mount_dir_base` | no | `/var/lib/armbian/disk_provision_mnt` | Base for per-device temporary mount points. |
| `render_only` | no | `false` | Render `.repart.d` configs + validate, then return without mutating the disk. Used by Layer 1 molecule tests. |

The per-partition `layout` entry shape — `id`, `size`, `type`, `format`,
`label`, `mount`, `mount_opts`, `preserve_on_reprovision` — is fully
described in the argument_specs file.

## Outputs / side effects

After a successful run:

- `disk_binding.device` carries the GPT layout described by `layout`.
- Every partition in `layout` is formatted with the requested filesystem
  and (when `label` is given) labelled.
- Partitions marked `preserve_on_reprovision: true` with a matching
  label already on disk are skipped from wipe and rsync — pre-existing
  data is retained.
- The root partition (`type: root`) is populated from `source` via rsync.
- `/etc/fstab` on the root partition references every layout entry that
  has a `mount` set, by `LABEL=`.
- When `armbian_installed_marker: true`: `/etc/armbian-image-release`
  on the target carries `INSTALLED=true`.
- All temporary mount points under `mount_dir_base` are unmounted at
  the end of the run.

## Idempotency & check mode

- **Preserve idempotency.** A partition declared
  `preserve_on_reprovision: true` whose `label` already exists on the
  disk is skipped at the `systemd-repart` step and excluded from the
  rsync populate step. Set `force: true` on the binding to bypass
  preservation and destructively re-partition.
- **Wipe-aware audit mode.** When `wipe: false`, the role fails if the
  disk's current layout doesn't already match — useful for asserting
  expected state without mutating the disk.
- **Render-only mode.** `render_only: true` performs validation and
  config rendering, then ends the host before any mutation. Used by the
  WS-7 molecule scenario.
- **`--check` mode.** Not currently supported beyond what
  `systemd-repart --dry-run` does upstream; running with `--check`
  exercises validation but skips the populate step.

## Example

```yaml
- name: Provision the local NVMe for orange-pi-5-pro-01
  hosts: orange-pi-5-pro-01
  become: true
  vars:
    armbian_local_disks:
      - device: /dev/nvme0n1
        wipe: true
        layout:
          - id: 01-esp
            size: 256MiB
            type: esp
            format: vfat
            label: ESP
            mount: /boot/efi
          - id: 02-root
            size: grow
            type: root
            format: ext4
            label: armbi_root_local
            mount: /
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian.disk_provision
      vars:
        disk_binding: "{{ armbian_local_disks[0] }}"
        source: /
        reset_identity: false
```
