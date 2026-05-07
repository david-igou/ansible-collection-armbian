# routeros_dhcp

Manages MikroTik RouterOS DHCP option objects so a board's PXE behaviour
*should* be controllable entirely from the router. The intended invariant:
U-Boot tries PXE first and falls through to disk when DHCP provides no
`next-server`, so flipping the lease's option set is enough to toggle a
board's boot mode.

> **WIP.** Stock Armbian Rockchip `current` debs don't deliver this invariant —
> their compile-time `BOOT_TARGETS` puts PXE at position 6, behind mmc1 where the
> SD card's `boot.scr` wins via `bootflow scan`. This role's tasks (creating DHCP
> option sets, writing `pxelinux.cfg/01-<mac>`, flipping the lease's option) are
> correct in isolation, but `enable_netboot` won't actually cause the board to
> PXE-boot until the board has been flashed with a custom Armbian U-Boot deb
> built by the `armbian_build` role
> ([#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16)).
> Empirical evidence:
> [issue #2](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/2).

The role has four task entry-points, each designed to be included from a
play with the right `hosts:` target:

- `setup_options.yml` — `hosts: routeros_routers`. Runs once. Creates
  the DHCP option objects (option 66 / 67) and the `armbian-nfsroot`
  option set that bundles them.
- `write_pxelinux_cfg.yml` — `hosts: netboot_server` (`become: true`).
  Writes `pxelinux.cfg/01-<mac>` on the netboot server's TFTP root over
  SSH. No NFS mount on the control node. Required vars: `board_mac`,
  `board_model`, `target_board_host`.
- `enable_netboot.yml` — `hosts: routeros_routers`. Sets
  `dhcp-option=armbian-nfsroot` on a board's static lease. Run after
  `write_pxelinux_cfg.yml` (the file must exist before the board renews
  DHCP).
- `disable_netboot.yml` — `hosts: routeros_routers`. Clears the lease's
  `dhcp-option` so the board boots from disk on next DHCP renewal.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `routeros_dhcp_server_name` | `dhcp1` | DHCP server name on RouterOS. |
| `routeros_opt_tftp_name` | `armbian-tftp-server` | DHCP option object name for option 66 (TFTP server). |
| `routeros_opt_set_nfsroot_prefix` | `armbian-nfsroot` | Option-set name for nfsroot mode. |
| `netboot_modes` | *(see defaults)* | Map of mode name to TFTP `pxelinux.cfg` filename. |

SSH connection identity (`ansible_host`, `ansible_user`, `ansible_port`) lives
on the RouterOS host entry in `inventory/hosts.yml`, not on collection-level
variables. Authentication is SSH-key based — provision the user and key with
`playbooks/bootstrap_routeros_user.yml` before running this role.

## Example

```yaml
- name: Enable PXE netboot for a board
  hosts: rock-5b-01
  roles:
    - role: david_igou.armbian_netboot.routeros_dhcp
      vars:
        routeros_action: enable
```

Most users invoke this role indirectly via `enable_netboot.yml`,
`disable_netboot.yml`, and `setup_routeros_dhcp.yml`.

## License

GPL-3.0-or-later
