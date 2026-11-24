# board_boot_verify

Asserts that a board's root filesystem matches the boot mode it is supposed to
be in, so a silent fall-through (PXE skipped, U-Boot booted the SD card) is
caught before later plays act on the wrong system. Runs on the board; gathers
only the `mounts` fact subset itself.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Required | Purpose |
|---|---|---|
| `board_boot_verify_mode` | yes | `nfs`, `sd`, `local`, `local_kernel` or a custom mode name |
| `board_boot_verify_root_match` | custom modes only | Regex the root device must match; replaces the mode's default |

| Mode | Root fstype | Root device must match (default) |
|---|---|---|
| `nfs` | `nfs` or `nfs4` | not checked |
| `sd` | not NFS | `^/dev/` |
| `local` | not NFS | `^/dev/` |
| `local_kernel` | not NFS | `^/dev/nvme` |
| custom | not checked | `board_boot_verify_root_match` |

The modes and their defaults are one table in [`vars/main.yml`](vars/main.yml).
On mismatch the role fails with the actual root device and fstype, what was
expected, and a mode-specific hint.

## Example

```yaml
- name: Verify the boot mode
  hosts: boards
  gather_facts: false
  tasks:
    - name: Assert the board booted from NFS
      ansible.builtin.include_role:
        name: david_igou.armbian.board_boot_verify
      vars:
        board_boot_verify_mode: nfs

    - name: Assert a board with an eMMC fallback booted its local kernel
      ansible.builtin.include_role:
        name: david_igou.armbian.board_boot_verify
      vars:
        board_boot_verify_mode: local_kernel
        board_boot_verify_root_match: ^/dev/(nvme|mmcblk0)
```

## Idempotency and check mode

Read-only: gathers facts and asserts. Works in check mode.

## License

MIT
