# pxelinux_render

## Purpose

Render one per-board pxelinux.cfg file to a local directory. Given the
board's MAC, model identity, console, and the netboot parameters the
collection currently runs against, the role produces an `01-<mac>`
pxelinux config file containing labels for every supported boot mode
(`nfs`, `sd`, `local`, `local_kernel`, plus any user-defined entries in
`pxelinux_render_extra_modes`) with a `default` directive pointed at the
requested mode.

Always writes; never uploads. The caller is responsible for moving the
rendered file to the TFTP server — typically via `delegate_to:
localhost` inside a `hosts: boards` play, so each board's hostvars are
in scope and one invocation per board renders one file.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Required | Default | Purpose |
|---|---|---|---|
**Prerequisite:** the calling playbook must resolve `armbian_board_config` on the running host (via `playbooks/tasks/_resolve_board_config.yml`) before invoking this role. The template reads `armbian_board_config.console`, `armbian_board_config.earlycon`, and `armbian_board_config.armbian_board_name` directly.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `pxelinux_render_board_mac` | yes | — | Board MAC address; used to compute the `01-<mac>` filename. |
| `pxelinux_render_boot_mode` | yes | — | Which label's body the rendered `default` directive points at. Built-ins: `nfs`, `sd`, `local`, `local_kernel`. May also be any key in `pxelinux_render_extra_modes`. |
| `pxelinux_render_nfs_server_ip` | yes | — | Server IP written into `nfsroot=`. |
| `pxelinux_render_nfs_root_path` | yes | — | NFS export root; per-host directory is composed as `<pxelinux_render_nfs_root_path>/<pxelinux_render_hostname>`. |
| `pxelinux_render_hostname` | yes | — | Inventory hostname — used as both the per-host NFS subdir and the menu-label suffix. |
| `pxelinux_render_output_dir` | yes | — | Local directory where `01-<mac>` is written. |
| `pxelinux_render_extra_modes` | no | `{}` | User-defined named boot modes (key → `{root, rootfstype, verify_match}`). |
| `pxelinux_render_sd_root` | no | `LABEL=armbi_root` | `root=` kernel argument for the `sd` label. |
| `pxelinux_render_local_root` | no | `LABEL=armbi_root_local` | `root=` kernel argument for the `local` label. Must match what `disk_provision` wrote at mkfs time. |
| `pxelinux_render_pxe_verbose` | no | `false` | When true, append `earlycon` (from `armbian_board_config.earlycon`) + verbose kernel params to every label. |
| `pxelinux_render_tftp_kernel` / `_tftp_initrd` / `_tftp_dtb` | no | `armbian/{{ inventory_hostname }}/...` | TFTP-relative paths written verbatim into pxelinux.cfg. Per-host by default. |

## Outputs / side effects

After a successful run:

- `{{ pxelinux_render_output_dir }}/01-<mac>` exists and is mode `0644`.
- The rendered file contains one `default` directive selecting
  `pxelinux_render_boot_mode`, plus labels for every built-in mode
  (`nfs`, `sd`, `local`, `local_kernel`) and every key in
  `pxelinux_render_extra_modes`.
- No network calls; no uploads; no other filesystem mutations.

## Idempotency & check mode

- Backed by `ansible.builtin.template`, which only reports `changed`
  when the rendered content differs from what is already on disk.
- `--check` mode is fully supported: the role reports `changed`
  accurately without writing.
- Validation: the role hard-fails at task time if
  `pxelinux_render_boot_mode` is neither a built-in nor a key in
  `pxelinux_render_extra_modes`, and if `pxelinux_render_pxe_verbose=true`
  is set without `armbian_board_config.earlycon` resolved. Both checks
  run before the file is written.

## Example

```yaml
- name: Render this board's pxelinux.cfg locally
  hosts: boards
  gather_facts: false
  pre_tasks:
    - ansible.builtin.include_tasks: tasks/_resolve_board_config.yml
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian.pxelinux_render
      delegate_to: localhost
      vars:
        pxelinux_render_board_mac: "{{ armbian_board_mac }}"
        pxelinux_render_boot_mode: "{{ armbian_boot_mode }}"
        pxelinux_render_nfs_server_ip: "{{ armbian_nfs_server_ip }}"
        pxelinux_render_nfs_root_path: "{{ armbian_nfs_rootfs_path }}"
        pxelinux_render_hostname: "{{ inventory_hostname }}"
        pxelinux_render_output_dir: "{{ playbook_dir }}/../.cache/pxelinux.cfg"
```

Typically reached via `playbooks/converge_boot_mode.yml`, which then
hands the rendered files off to the RouterOS upload reference
playbook.
