# pxelinux_render

Renders one board's pxelinux.cfg (`01-<mac>`) into a local directory. The file
carries a label for every boot mode, and its `default` line selects the active
one, so switching modes rewrites one line. The role never uploads; the caller
copies the file to its TFTP server. Usually run with `delegate_to: localhost`
inside a play on the boards, so each board's variables are in scope.

## Boot modes

| Mode | Label body |
|---|---|
| `nfs` | kernel + initrd (+ dtb), `root=/dev/nfs nfsroot=<server>:<root path>/<hostname>,nfsvers=<n>` |
| `sd` | kernel + initrd (+ dtb), `root=<pxelinux_render_sd_root>` |
| `local` | kernel + initrd (+ dtb), `root=<pxelinux_render_local_root>` |
| `local_kernel` | `localboot 0`: U-Boot's `localcmd` boots the local disk's own kernel |
| extra | one label per `pxelinux_render_extra_modes` key |

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `pxelinux_render_board_mac` | yes | | File name `01-<mac>` (lower case, dashes) |
| `pxelinux_render_boot_mode` | yes | | Label selected by `default` |
| `pxelinux_render_console` | yes | | Kernel `console=` |
| `pxelinux_render_nfs_server_ip` | yes | | `nfsroot=` server |
| `pxelinux_render_nfs_root_path` | yes | | NFS export root; the board's root is `<path>/<hostname>` |
| `pxelinux_render_hostname` | yes | | Per-host NFS directory and menu-label suffix |
| `pxelinux_render_output_dir` | yes | | Local output directory |
| `pxelinux_render_earlycon` | with verbose | `""` | Kernel `earlycon=` |
| `pxelinux_render_board_name` | no | `""` | Shown in the header comment |
| `pxelinux_render_nfs_version` | no | `3` | `nfsvers=` |
| `pxelinux_render_extra_modes` | no | `{}` | `{name: {menu_label, root, rootfstype, extra_append}}` |
| `pxelinux_render_sd_root` | no | `LABEL=armbi_root` | `root=` of the `sd` label |
| `pxelinux_render_local_root` | no | `LABEL=armbi_root_local` | `root=` of the `local` label |
| `pxelinux_render_pxe_verbose` | no | `false` | Append earlycon and verbose logging arguments |
| `pxelinux_render_tftp_kernel` | no | `armbian/<inventory_hostname>/vmlinuz` | TFTP path of the kernel |
| `pxelinux_render_tftp_initrd` | no | `armbian/<inventory_hostname>/initrd.img` | TFTP path of the initrd |
| `pxelinux_render_tftp_dtb` | no | `armbian/<inventory_hostname>/board.dtb` | TFTP path of the dtb; empty renders no `fdt` line |

## Outputs

| Fact | Value |
|---|---|
| `pxelinux_render_filename` | `01-<mac>` |
| `pxelinux_render_file` | `<pxelinux_render_output_dir>/01-<mac>` |

## Example

```yaml
- name: Render pxelinux.cfg for each board
  hosts: boards
  gather_facts: false
  tasks:
    - name: Render on the control node
      ansible.builtin.include_role:
        name: david_igou.armbian.pxelinux_render
        apply:
          delegate_to: localhost
      vars:
        pxelinux_render_board_mac: "{{ board_mac }}"
        pxelinux_render_boot_mode: nfs
        pxelinux_render_console: "{{ board_config.console }}"
        pxelinux_render_nfs_server_ip: 192.0.2.10
        pxelinux_render_nfs_root_path: /srv/netboot/rootfs
        pxelinux_render_hostname: "{{ inventory_hostname }}"
        pxelinux_render_output_dir: "{{ playbook_dir }}/.cache/pxelinux.cfg"

    - name: Show the file to upload
      ansible.builtin.debug:
        msg: "{{ pxelinux_render_file }}"
```

Rendered with the `nfs` mode for `board-01`:

```text
#
# Ansible managed
#
# pxelinux.cfg for board-01 (rock-5b)
# MAC: AA:BB:CC:DD:EE:FF

default nfs
timeout 50
prompt  0

label nfs
  menu label Armbian NFS root (board-01)
  kernel armbian/board-01/vmlinuz
  initrd armbian/board-01/initrd.img
  fdt    armbian/board-01/board.dtb
  append root=/dev/nfs nfsroot=192.0.2.10:/srv/netboot/rootfs/board-01,nfsvers=3,rw ip=dhcp rootwait rw console=ttyS2,1500000

label sd
  ...
label local
  ...
label local_kernel
  menu label Boot the local disk's kernel (board-01)
  localboot 0
```

## Idempotency and check mode

`ansible.builtin.template` reports a change only when the content differs.
Check mode is supported.

## License

MIT
