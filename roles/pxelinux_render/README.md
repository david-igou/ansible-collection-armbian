# pxelinux_render

## Purpose

Render one per-board pxelinux.cfg file to a local directory. Given the
board's MAC, model identity, console, and the netboot parameters the
collection currently runs against, the role produces an `01-<mac>`
pxelinux config file containing labels for every supported boot mode
(`nfs`, `sd`, `local`, `local_kernel`, plus any user-defined entries in
`extra_modes`) with a `default` directive pointed at the requested
mode.

Always writes; never uploads. The caller is responsible for moving the
rendered file to the TFTP server — typically via `delegate_to:
localhost` inside a `hosts: boards` play, so each board's hostvars are
in scope and one invocation per board renders one file.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `board_mac` | yes | — | Board MAC address; used to compute the `01-<mac>` filename. |
| `boot_mode` | yes | — | Which label's body the rendered `default` directive points at. Built-ins: `nfs`, `sd`, `local`, `local_kernel`. May also be any key in `extra_modes`. |
| `board_console` | yes | — | `console=` kernel argument value (e.g. `ttyS2,1500000`). |
| `model_name` | yes | — | Board model identifier — composes the default TFTP paths. |
| `nfs_server_ip` | yes | — | Server IP written into `nfsroot=`. |
| `nfs_root_path` | yes | — | NFS export root; per-host directory is composed as `<nfs_root_path>/<hostname>`. |
| `hostname` | yes | — | Inventory hostname — used as both the per-host NFS subdir and the menu-label suffix. |
| `output_dir` | yes | — | Local directory where `01-<mac>` is written. |
| `extra_modes` | no | `{}` | User-defined named boot modes (key → `{root, rootfstype, verify_match}`). |
| `sd_root` | no | `LABEL=armbi_root` | `root=` kernel argument for the `sd` label. |
| `local_root` | no | `LABEL=armbi_root_local` | `root=` kernel argument for the `local` label. Must match what `disk_provision` wrote at mkfs time. |
| `pxe_verbose` | no | `false` | When true, append `earlycon` + verbose kernel params to every label. |
| `earlycon` | no | `""` | Required when `pxe_verbose=true`. Format `<driver>,<bus>,<mmio_addr>`. |
| `tftp_kernel` / `tftp_initrd` / `tftp_dtb` | no | `armbian/{{ model_name }}/...` | TFTP-relative paths written verbatim into pxelinux.cfg. |

## Outputs / side effects

After a successful run:

- `{{ output_dir }}/01-<mac>` exists and is mode `0644`.
- The rendered file contains one `default` directive selecting
  `boot_mode`, plus labels for every built-in mode (`nfs`, `sd`,
  `local`, `local_kernel`) and every key in `extra_modes`.
- No network calls; no uploads; no other filesystem mutations.

## Idempotency & check mode

- Backed by `ansible.builtin.template`, which only reports `changed`
  when the rendered content differs from what is already on disk.
- `--check` mode is fully supported: the role reports `changed`
  accurately without writing.
- Validation: the role hard-fails at task time if `boot_mode` is
  neither a built-in nor a key in `extra_modes`, and if
  `pxe_verbose=true` is set without `earlycon`. Both checks run
  before the file is written.

## Example

```yaml
- name: Render this board's pxelinux.cfg locally
  hosts: boards
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian_netboot.pxelinux_render
      delegate_to: localhost
      vars:
        board_mac: "{{ armbian_netboot_board_mac }}"
        boot_mode: "{{ armbian_netboot_boot_mode }}"
        board_console: "{{ board_config.console }}"
        model_name: "{{ armbian_netboot_board_model }}"
        nfs_server_ip: "{{ armbian_netboot_nfs_server_ip }}"
        nfs_root_path: "{{ armbian_netboot_nfs_rootfs_path }}"
        hostname: "{{ inventory_hostname }}"
        output_dir: "{{ playbook_dir }}/../.cache/pxelinux.cfg"
```

Typically reached via `playbooks/converge_boot_mode.yml`, which then
hands the rendered files off to the RouterOS upload reference
playbook.
