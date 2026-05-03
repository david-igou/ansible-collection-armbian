# routeros_dhcp

Manages MikroTik RouterOS DHCP option objects so a board's PXE behaviour can
be controlled entirely from the router. This is the only control surface
needed to switch boards between disk boot and netboot — U-Boot always tries
PXE first and falls through to disk when DHCP provides no `next-server`.

The role has three task entry-points:

- `setup_options.yml` — runs once. Creates per-mode DHCP option objects
  (option 66 / 67) and the `armbian-nfsroot` and `armbian-reprovision`
  option sets that bundle them.
- `enable_netboot.yml` — sets `dhcp-option=armbian-nfsroot` or
  `armbian-reprovision` on a board's static lease, optionally rebooting it.
- `disable_netboot.yml` — clears the lease's `dhcp-option` so the board
  boots from disk on next DHCP renewal.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `routeros_dhcp_server_name` | `dhcp1` | DHCP server name on RouterOS. |
| `routeros_opt_tftp_name` | `armbian-tftp-server` | DHCP option object name for option 66 (TFTP server). |
| `routeros_opt_set_nfsroot_prefix` | `armbian-nfsroot` | Option-set name for nfsroot mode. |
| `routeros_opt_set_reprovision_prefix` | `armbian-reprovision` | Option-set name for reprovision mode. |
| `netboot_modes` | *(see defaults)* | Map of mode name to TFTP `pxelinux.cfg` filename. |

`routeros_host`, `routeros_api_user`, and `routeros_api_password` must be set
elsewhere (typically in `inventory/group_vars/routeros.yml` and encrypted
with ansible-vault).

## Example

```yaml
- name: Enable PXE reprovision mode for a board
  hosts: rock-5b-01
  roles:
    - role: david_igou.armbian_netboot.routeros_dhcp
      vars:
        routeros_action: enable
        netboot_mode: reprovision
```

Most users invoke this role indirectly via `enable_netboot.yml`,
`disable_netboot.yml`, and `setup_netboot.yml`.

## License

GPL-3.0-or-later
