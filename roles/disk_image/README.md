# disk_image

Single-purpose, transport-agnostic role. Streams an `.img.xz` or raw
`.img` to a block device via `curl | xz -dc | dd` (or `dd` direct for
raw images) with `set -o pipefail`. Refuses to write to a target whose
partition table currently backs a mounted filesystem.

## When to use

- Reimage the SD card from an NFS-booted board (fleet-test Phase 0
  state reset).
- Reimage an NVMe device from any rootfs that isn't on it.

## Inputs

See `meta/argument_specs.yml`. Required: `image_source`, `target_device`.
Optional: `dd_bs` (default `4M`).

## Example

```yaml
- ansible.builtin.include_role:
    name: disk_image
  vars:
    image_source: "https://images.example.org/orange-pi-5-pro.img.xz"
    target_device: /dev/mmcblk0
```

## Prerequisites

The running rootfs must have `curl`, `xz`, `dd`, `sync`, and `partprobe`
(from `parted`) installed. All present in stock Armbian.

## What this role does NOT do

- Reset identity (machine-id, ssh host keys, hostname).
- Resize partitions.
- Verify image integrity (sha256). Streaming means a corrupt or
  truncated source leaves a partial image on the target — re-invoke
  to recover.
