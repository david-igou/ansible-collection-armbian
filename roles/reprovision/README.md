# reprovision

Flashes a fresh Armbian image to a board's primary storage device.

Runs **on the board itself** via SSH while it is booted into the NFS root
environment (set up by the `nfs_content` role and triggered by the
`routeros_dhcp` role's reprovision-mode DHCP options). The role:

1. Resolves the target block device from `board_model` (`/dev/nvme0n1` or
   `/dev/mmcblk0`).
2. Downloads the per-board `.img.xz` from netboot.xyz's HTTP assets server.
3. Decompresses with `xz` and writes to the device with `dd`.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `image_server_url` | `http://{{ netboot_server_ip }}:8080/assets/images` | HTTP base URL for `<board_model>.img.xz`. |
| `flash_download_timeout` | `300` | Seconds to wait for the image download to finish. |
| `flash_timeout` | `900` | Seconds to wait for the `xz \| dd` flash to finish. |

The `board_model` host variable is required; it must match a key in
`bootloader/vars/boards.yml`.

## Example

```yaml
- name: Flash Armbian image to disk
  hosts: rock-5b-01
  roles:
    - role: david_igou.armbian_netboot.reprovision
```

This role is normally invoked from the higher-level `reprovision.yml`
playbook, which also handles enabling/disabling the reprovision DHCP option
and rebooting between phases.

## License

GPL-3.0-or-later
