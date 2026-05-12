# routeros_sbc_tftp

Manages per-board `pxelinux.cfg/01-<MAC>` files on rb5009's flash and the
corresponding `/ip tftp` rows so U-Boot's PXE bootmeth can fetch the
config when the board DHCPs. Adding the file + row puts the board into
NFS-root mode; removing them lets the board fall through to its local SD
rootfs. This pair of file presence + `/ip tftp` row is the v1 collection's
sole control surface — there are no DHCP option-sets, no lease mutations,
no on-board state to mutate.

This is achievable only because the U-Boot binary on the SD card has been
compiled with `BOOT_TARGETS` ordered with `pxe` first. Stock Armbian
Rockchip `current` ships PXE at position 6, behind mmc1 where the SD
card's `boot.scr` wins via `bootflow scan`. Until the board has been
flashed with a custom Armbian image built by the `armbian_build` role,
this role's writes will land correctly on rb5009 but the board itself
won't actually try PXE.
See [issue #2](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/2)
for empirical evidence on stock images.

The role exposes two task entry-points, both designed to be included with
`hosts: routeros_routers` (network_cli):

- `write_pxelinux_cfg.yml` — renders the per-board `pxelinux.cfg/01-<MAC>`
  locally from the Jinja template, `net_put`s it to
  `flash:/<sbc_tftp_flash_dir>/pxelinux.cfg/01-<MAC>` on rb5009, and
  registers a matching `/ip tftp` row. Required vars: `board_mac`,
  `board_model`, `target_board_host`. Idempotent — gates on file size
  and `/ip tftp` row count.
- `remove_pxelinux_cfg.yml` — removes the `/ip tftp` row first (so a
  stale request fails closed if `/file remove` later errors), then
  removes the file from rb5009's flash. Required var: `board_mac`.
  Idempotent.

The corresponding per-model assets (kernel/initrd/dtb under
`flash:/<sbc_tftp_flash_dir>/armbian/<model>/`) are owned by the
`netboot_assets` role's `stage_rb5009.yml` task — not this role.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `sbc_tftp_flash_dir` | `sbc` | Top-level directory on rb5009's flash for SBC TFTP content. Used as the `name=` prefix in `/file` paths and as the `real-filename` prefix in `/ip tftp` rules. Mirrored as a default in `roles/netboot_assets/defaults/main.yml`. |

SSH connection identity (`ansible_host`, `ansible_user`, `ansible_port`) lives
on the RouterOS host entry in `inventory/hosts.yml`, not on collection-level
variables. Authentication is SSH-key based — provision the user and key with
`playbooks/bootstrap_routeros_user.yml` before running this role.

## Example

Most users invoke this role indirectly via `enable_netboot.yml` and
`disable_netboot.yml`. To call it directly:

```yaml
- name: Enable PXE netboot for a board
  hosts: routeros_routers
  gather_facts: false
  tasks:
    - name: Write per-board pxelinux.cfg + /ip tftp row
      ansible.builtin.include_role:
        name: david_igou.armbian_netboot.routeros_sbc_tftp
        tasks_from: write_pxelinux_cfg.yml
      vars:
        board_mac: "aa:bb:cc:dd:ee:11"
        board_model: orange-pi-5-pro
        target_board_host: orange-pi-5-pro-01
```

## License

GPL-3.0-or-later
