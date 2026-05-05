# bootloader

Flashes PXE-capable U-Boot for Armbian-based ARM SBCs. Per-SoC-family
strategies live in `vars/socs/<family>.yml` (current: `rockchip`,
`allwinner`); add new families by dropping in a vars file plus, if the
eMMC layout differs, a `tasks/flash_emmc_<strategy>.yml` file.

Three flash targets are supported, chosen from each board's capability
flags (`has_spi`, `has_emmc` in `vars/boards.yml`) and the
`bootloader_target` setting. All three run **on the board itself** over
SSH — there is no separate netboot-server-side SD card prep step:

- **SPI** — installs the Armbian U-Boot apt package and writes
  `u-boot-rockchip-spi.bin` to the SPI MTD device. Detection is by MTD
  partition label; falls back to `spi_mtd_device` when no labeled
  partition matches.
- **eMMC** — writes `u-boot-rockchip.bin` to the eMMC boot partition
  (`/dev/mmcblk0boot0` by default). Stat-checks the device and its
  `force_ro` sysfs attribute first; aborts if the eMMC isn't actually
  populated, which prevents accidentally clobbering an SD card.
- **SD card** — writes U-Boot to the SD card the board is currently
  booted from, in place, at the SoC family's `sd_uboot_seek_sectors`
  offset (Rockchip 64, Allwinner 16). Hard-fails if the rootfs is not
  on a removable SD card — refuses to overwrite eMMC or NVMe under
  this code path. Use this for boards with no SPI/eMMC populated; the
  operator is expected to have flashed Armbian to the SD card
  manually before this point.

For `bootloader_target=auto` (default) the role picks the most permanent
storage available: SPI if populated and detected, else eMMC if
populated, else the SD card the board is booted from.

> **WIP — netboot trigger.** Flashing this role's binaries does **not** by
> itself deliver "RouterOS DHCP option flip → board PXE-boots." Modern
> Armbian Rockchip `current` debs build with `BOOT_TARGETS "mmc1 mmc0 nvme
> scsi usb pxe dhcp spi"` (PXE at position 6) and an SD-card-booted
> Armbian install hits `bootmeth_script` on mmc1 before bootflow scan
> reaches PXE. See
> [issue #2](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/2)
> for the empirical analysis and
> [issue #3](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/3)
> for the design discussion on a portable fix.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `bootloader_target` | `auto` | Force flash target. One of `auto`, `spi`, `emmc`, `sd`. `auto` prefers SPI when populated and detected, then eMMC, then the SD card the board is currently booted from. |
| `uboot_package_lib_dir` | `/usr/lib` | Directory where the Armbian U-Boot package installs binaries. |
| `spi_mtd_device` | `/dev/mtd0` | Fallback SPI MTD device when label-based detection finds nothing. |
| `emmc_boot_partition` | `/dev/mmcblk0boot0` | Fallback eMMC boot partition. |
| `bootloader_skip_if_present` | `false` | Skip flashing if a valid bootloader is already present. |

`board_model` is a required host variable — it must match a key in
`vars/boards.yml`.

`host_board_overrides` is an optional per-host dict that shadows
individual `board_configs` fields (e.g. one Rock 5B unit with populated
SPI while another doesn't). See the project root `CLAUDE.md`.

## Example

```yaml
- name: Flash U-Boot
  hosts: rock-5b-01
  roles:
    - role: david_igou.armbian_netboot.bootloader
```

## License

GPL-3.0-or-later
