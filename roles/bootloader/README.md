# bootloader

Flashes PXE-capable U-Boot for RK3588/RK3588S Armbian boards.

Two paths are supported, selected by `has_spi` in `vars/boards.yml`:

- **SPI/eMMC** — runs on the board itself. Installs the Armbian U-Boot apt
  package (board must already be running Armbian with internet access) and
  writes the binary to `/dev/mtd0` (SPI) or `/dev/mmcblk0boot0` (eMMC).
- **SD card** — runs on the Ansible control node via `prepare_sd_card.yml`.
  Writes U-Boot to an SD card at sector 64 and configures `boot_targets` so
  the card behaves identically to SPI flash on boards without SPI.

After flashing, RouterOS DHCP options become the only mechanism needed to
switch a board between disk boot and netboot.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `bootloader_target` | `auto` | Force flash target. One of `auto`, `spi`, `emmc`. |
| `uboot_package_lib_dir` | `/usr/lib` | Directory where the Armbian U-Boot package installs binaries. |
| `spi_mtd_device` | `/dev/mtd0` | SPI MTD device to write to. |
| `emmc_boot_partition` | `/dev/mmcblk0boot0` | eMMC boot partition for RK3588 bootloader. |
| `bootloader_skip_if_present` | `false` | Skip flashing if a valid bootloader is already present. |

The `board_model` host variable is required — it must match a key in
`vars/boards.yml`.

## Example

```yaml
- name: Flash U-Boot to SPI
  hosts: rock-5b-01
  roles:
    - role: david_igou.armbian_netboot.bootloader
```

## License

GPL-3.0-or-later
