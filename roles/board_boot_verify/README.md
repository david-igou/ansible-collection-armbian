# board_boot_verify

## Purpose

Assert that a board's currently-mounted rootfs matches the declared
`boot_mode`. Single-host role: gathers facts, inspects
`ansible_mounts['/']`, and asserts that the fstype + device path are
consistent with the boot mode the caller claims is active. Used to
catch silent fall-through (e.g. PXE skipped pxelinux.cfg and U-Boot
fell to the local SD card) before downstream plays mutate state under
the wrong assumption.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `boot_mode` | yes | — | One of `nfs`, `sd`, `local`, `local_kernel`, or a key in `extra_modes`. |
| `extra_modes` | no | `{}` | Mirrors `armbian_extra_modes`. When `boot_mode` is a key here, the role reads that mode's `verify_match` regex and asserts `ansible_mounts['/'].device` matches it. |
| `local_kernel_verify_match` | no | `^/dev/nvme` | Regex the rootfs device must match when `boot_mode=local_kernel`. Falls back to `armbian_board_config.local_kernel.verify_match` when that is resolved on the host. Widen for boards with non-NVMe localcmd fallbacks, e.g. `^/dev/(nvme\|mmcblk0)`. |

### Built-in assertion table

| `boot_mode` | rootfs fstype must be | rootfs device must |
|---|---|---|
| `nfs` | `nfs` or `nfs4` | — |
| `sd` | NOT nfs/nfs4 | start with `/dev/` |
| `local` | NOT nfs/nfs4 | start with `/dev/` |
| `local_kernel` | NOT nfs/nfs4 | match `local_kernel_verify_match` (default `^/dev/nvme`) |
| key in `extra_modes` | — | match the mode's `verify_match` regex |

## Outputs / side effects

After a successful run:

- The board's rootfs matches the declared mode (otherwise the role
  hard-fails with a mode-specific `fail_msg` describing the most
  likely upstream cause — wrong pxelinux fall-through, wrong U-Boot
  `localcmd`, missing partition label, etc.).
- No filesystem or configuration mutations on the board.

## Idempotency & check mode

- Pure read-only assertion role; running it twice with the same boot
  mode produces the same result.
- `--check` mode is fully supported — `setup` and `assert` both work
  in check mode.

## Example

```yaml
- name: Verify the board is on the declared boot mode
  hosts: orange-pi-5-pro-01
  gather_facts: true   # role inspects ansible_mounts['/']
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian.board_boot_verify
      vars:
        boot_mode: "{{ armbian_boot_mode }}"
        extra_modes: "{{ armbian_extra_modes | default({}) }}"
```

Typically reached via `playbooks/converge_boot_mode.yml` and
`playbooks/tests/test_hardware_e2e.yml` as the post-boot assertion step.
