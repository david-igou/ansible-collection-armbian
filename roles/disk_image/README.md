# disk_image

Stream an `.img.xz` or raw `.img` onto a whole block device. The source is
read with `curl -fsSL` (http/https URL) or `cat` (absolute path), piped
through `xz -dc` for `.img.xz`, and written with `dd conv=fsync` under
`set -o pipefail`. Afterwards the role runs `sync`, `partprobe` and
`udevadm settle` so the new partition nodes exist when the role returns.

## Inputs

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `disk_image_source` | yes | — | http(s) URL or absolute path. Format is chosen by extension: `.img.xz` or `.img`. |
| `disk_image_target_device` | yes | — | Whole-disk block device to overwrite, e.g. `/dev/mmcblk0`. |
| `disk_image_dd_bs` | no | `4M` | dd block size. |

The role sets no facts.

## Preconditions and refusals

The role fails before writing when:

- it runs in check mode;
- the target is not a block device, or is a partition node
  (`/sys/class/block/<name>/partition` exists);
- the target or any of its partitions is mounted (`lsblk MOUNTPOINTS`);
- the source is neither an http(s) URL nor an absolute path;
- the source does not end in `.img` or `.img.xz`;
- a local source is not a regular file.

The host needs `curl`, `xz`, `dd`, `lsblk`, `partprobe` (parted) and
`udevadm`; stock Armbian has them. The role escalates with `become` for the
write.

## Example

```yaml
- name: Reimage a board's SD card
  hosts: orange-pi-5-pro-01
  gather_facts: false
  tasks:
    - name: Stream the image onto the SD card
      ansible.builtin.include_role:
        name: david_igou.armbian.disk_image
      vars:
        disk_image_source: https://images.example.org/orange-pi-5-pro.img.xz
        disk_image_target_device: /dev/mmcblk0
```

## Idempotency and recovery

The role always writes the full image and reports `changed`. It does not
verify the image checksum; a failed or truncated stream leaves the device
in an unknown state, and re-running with a good source recovers it. Verify
the image out of band (for example against its `.sha` sidecar) first.
