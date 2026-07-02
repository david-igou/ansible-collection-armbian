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

See `meta/argument_specs.yml`. Required: `disk_image_source`, `disk_image_target_device`.
Optional: `disk_image_dd_bs` (default `4M`).

## Example

```yaml
- name: Reimage a board's SD card from a published .img.xz
  hosts: orange-pi-5-pro-01
  become: true
  gather_facts: false
  tasks:
    - name: Stream the image onto the target device
      ansible.builtin.include_role:
        name: david_igou.armbian.disk_image
      vars:
        disk_image_source: "https://images.example.org/orange-pi-5-pro.img.xz"
        disk_image_target_device: /dev/mmcblk0
        disk_image_dd_bs: 4M
```

## Prerequisites

The running rootfs must have `curl`, `xz`, `dd`, `sync`, and `partprobe`
(from `parted`) installed. All present in stock Armbian.

## Idempotency & check mode

The role always writes; there is no idempotency cache — every invocation
streams the full image to the target. Not check-mode safe: the role
asserts and exits early when `ansible_check_mode` is true, because
streaming writes to a block device cannot be simulated.

## Rollback / Recovery

A failed mid-stream write (curl error, xz CRC error, partial transfer)
leaves the target device in an unknown state. Recovery is always a clean
re-run: the role streams from the beginning with no partial-write
detection. A corrupt or truncated image leaves an unbootable device —
re-invoke with a known-good source to recover. Verify image integrity
out-of-band (e.g. via the `.sha` sidecar) before invoking this role
on a production board.

## What this role does NOT do

- Reset identity (machine-id, ssh host keys, hostname).
- Resize partitions.
- Verify image integrity (sha256). Streaming means a corrupt or
  truncated source leaves a partial image on the target — re-invoke
  to recover.
