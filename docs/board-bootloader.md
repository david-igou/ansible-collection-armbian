# Board Bootloader Reference

## Sample inventory boards

| Board            | SoC family | SoC       | SPI    | eMMC | Primary storage | DTB                                       |
|------------------|------------|-----------|--------|------|-----------------|-------------------------------------------|
| Orange Pi 5      | rockchip   | RK3588S   | Yes    | †    | NVMe            | rockchip/rk3588s-orangepi-5.dtb           |
| Orange Pi 5 Pro  | rockchip   | RK3588S   | No*    | †    | NVMe            | rockchip/rk3588s-orangepi-5-pro.dtb       |
| Orange Pi 5 Max  | rockchip   | RK3588    | Yes    | †    | NVMe            | rockchip/rk3588-orangepi-5-max.dtb        |
| Rock 5B          | rockchip   | RK3588    | Yes**  | †    | NVMe            | rockchip/rk3588-rock-5b.dtb               |
| Rock 5A          | rockchip   | RK3588S   | No***  | †    | NVMe            | rockchip/rk3588s-rock-5a.dtb              |
| Orange Pi Zero 3 | allwinner  | H618      | No     | No   | SD              | allwinner/sun50i-h616-orangepi-zero3.dtb  |

\* Orange Pi 5 Pro spec lists "SPI NOR Flash footprint" — most retail units
ship without the chip populated. Override `has_spi: true` via
`host_board_overrides` if your specific unit has SPI.

\** Rock 5B has an SPI socket but it may ship unpopulated.

\*** Rock 5A has no SPI populated by default.

† eMMC socket present on all RK3588 boards; the default `has_emmc: false`
matches typical retail (unpopulated). Override per-host if your unit has
eMMC populated.

## SoC family strategies

Per-board defaults inherited from `roles/bootloader/vars/socs/<family>.yml`
unless explicitly overridden in `boards.yml`:

| Family    | SD seek (sectors) | eMMC strategy      | SPI binary                  | Disk binary                 |
|-----------|-------------------|--------------------|-----------------------------|-----------------------------|
| rockchip  | 64                | boot_partition     | u-boot-rockchip-spi.bin     | u-boot-rockchip.bin         |
| allwinner | 16                | user_area_seek     | u-boot-sunxi-with-spl.bin   | u-boot-sunxi-with-spl.bin   |

`boot_partition` writes the disk binary to `/dev/mmcblkNboot0` at offset 0
(toggling `force_ro`). `user_area_seek` writes the disk binary to
`/dev/mmcblkN` at sector `emmc_seek_sectors` (defaulting to
`sd_uboot_seek_sectors`) without a boot partition.

## U-Boot package names (Armbian)

The apt package name and the install directory under `/usr/lib/` use
**different** segment orderings — always check both with `dpkg-deb -c`
when adding a new board.

| Board            | apt package                          | install dir                            |
|------------------|--------------------------------------|----------------------------------------|
| Orange Pi 5      | linux-u-boot-orangepi5-current       | linux-u-boot-current-orangepi5         |
| Orange Pi 5 Pro  | linux-u-boot-orangepi5pro-current    | linux-u-boot-current-orangepi5pro      |
| Orange Pi 5 Max  | linux-u-boot-orangepi5-max-edge      | linux-u-boot-edge-orangepi5-max        |
| Rock 5B          | linux-u-boot-rock-5b-current         | linux-u-boot-current-rock-5b           |
| Rock 5A          | linux-u-boot-rock-5a-current         | linux-u-boot-current-rock-5a           |
| Orange Pi Zero 3 | linux-u-boot-orangepizero3-current   | linux-u-boot-current-orangepizero3     |

## Flash targets

### SPI flash
Detected by `/sys/class/mtd/mtd*/name` (looking for `spi`/`nor`/`flash`/
`loader`/`boot`); falls back to the configured `spi_mtd_device`. The
binary written is the SoC family's `uboot_spi_image`.

```bash
# Rockchip example (auto-detected, e.g. /dev/mtd0)
dd if=/usr/lib/linux-u-boot-current-orangepi5/u-boot-rockchip-spi.bin \
   of=/dev/mtd0 bs=4096 conv=notrunc
```

### eMMC — boot_partition strategy (Rockchip)
```bash
echo 0 > /sys/block/mmcblk0boot0/force_ro
dd if=/usr/lib/linux-u-boot-current-rock-5b/u-boot-rockchip.bin \
   of=/dev/mmcblk0boot0 bs=512
echo 1 > /sys/block/mmcblk0boot0/force_ro
```

### eMMC — user_area_seek strategy (Allwinner and similar)
```bash
dd if=/usr/lib/linux-u-boot-current-orangepizero3/u-boot-sunxi-with-spl.bin \
   of=/dev/mmcblk0 bs=512 seek=16 conv=notrunc
```

### SD card (`flash_sd.yml`)
Runs on the board over SSH. Detects the SD device the board is booted
from (`findmnt -n -o SOURCE /` then `lsblk -no PKNAME`), asserts it's
removable / type SD, then `dd`s the U-Boot disk binary to it at sector
`sd_uboot_seek_sectors` (Rockchip=64, Allwinner=16).

```bash
# Allwinner example
dd if=/usr/lib/linux-u-boot-current-orangepizero3/u-boot-sunxi-with-spl.bin \
   of=/dev/mmcblk0 bs=512 seek=16 conv=notrunc
```

The operator is expected to have flashed Armbian to the SD card
manually first (etcher / `dd` / Armbian installer); `flash_sd.yml`
replaces that card's U-Boot in place.

## How PXE-first works — custom Armbian builds via the `armbian_build` role

> **Status: WIP pending [#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16).**
> The flashing role works. PXE-first ordering is delivered by a custom Armbian U-Boot
> build managed by the `armbian_build` role; until that role lands, stock Rockchip
> `current` debs reach the SD card's `boot.scr` before PXE and the netboot trigger
> doesn't fire. Empirical evidence:
> [issue #2](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/2)
> (verified on `linux-u-boot-orangepi5pro-current 26.2.0-trunk.821`, U-Boot v2025.10).

Modern Armbian Rockchip `current` debs build U-Boot with
`BOOTSTD_DEFAULTS=y` and `CONFIG_BOOTCOMMAND="bootflow scan -lb"`.
`bootflow scan` walks global bootmeths (only `efi_bootmgr` qualifies) and
then per-device bootmeths in the order set by the `boot_targets` env var,
which on first boot inherits the compile-time `BOOT_TARGETS` macro. With
PXE-first ordering and PXE/DHCP bootmeths enabled:

- DHCP returns `next-server` ⇒ pxe bootflow wins → board netboots.
- DHCP returns no next-server ⇒ scan falls through to local disk.

Stock Armbian doesn't ship PXE-first. `include/configs/rockchip-common.h`
in upstream U-Boot v2025.10 defines `BOOT_TARGETS "mmc1 mmc0 nvme scsi
usb pxe dhcp spi"` and Armbian's per-board configs (`orangepi5pro.csc`,
`orangepi5.conf`, `rock-5a.csc`, `rock-5b.conf` on `current`, …) don't
patch it. `bootflow scan -lb` walks mmc1 first; the SD card's
`/boot/boot.scr` is found by `bootmeth_script` and `booti`s the kernel
directly — PXE at positions 6/7 is unreachable.

Armbian's `BOOT_TARGETS` override pattern (a
`pre_config_uboot_target__*_patch_rockchip_common_boot_order` function in
the board's `.conf`/`.csc`) is established for `rock-5b` (edge only),
`nanopct6`, `cm3588-nas`, `mekotronics-r58s2`, `youyeetoo-r1-v3`,
`mixtile-blade3`, and others — but none of them put PXE first either.
The `armbian_build` role applies the same hook pattern locally with
`pxe dhcp` at the front.

### Why the role no longer touches U-Boot env

Armbian's debs build with `CONFIG_ENV_IS_NOWHERE=y` — U-Boot's env lives
only in RAM and is reset to compiled-in defaults on every boot. `fw_setenv`
is permanently a no-op on these debs, which is why the PXE-first ordering
has to come from the U-Boot binary itself rather than from a runtime env
override. A handful of upstream boards do opt into persistent env in the
Armbian build tree (e.g. `rock-5b` on `edge`, `rock-5b-plus`, `rock-5t`,
`odroidm1`, `nanopct6`); none are currently in this collection's inventory.

Probe a board's env mode:

```bash
grep -E '^CONFIG_(ENV_IS_|BOOTSTD|BOOTCOMMAND)' \
  /usr/lib/<install_dir>/u-boot-config-target-1
```

If `CONFIG_ENV_IS_NOWHERE=y` and you want a non-default boot order, the
fix is a compile-time patch to `BOOT_TARGETS` — which is what
[#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16)
delivers via the `armbian_build` role.

### Verifying U-Boot PXE support

After flashing, connect via serial and interrupt U-Boot. Check for the
`pxe` and `bootflow` commands:
```
=> help pxe
pxe - commands for PXE support
=> help bootflow
bootflow - Boot flows
```
If either is missing the U-Boot build does not support modern PXE
boot and the package version should be updated or rebuilt with
`CONFIG_CMD_PXE=y` and `CONFIG_BOOTSTD_DEFAULTS=y`.

## Adding a new board

1. If the SoC family is not yet supported, add a vars file under
   `roles/bootloader/vars/socs/<family>.yml` with the appropriate
   binary names, `sd_uboot_seek_sectors`, and `emmc_strategy`. For a
   strategy not yet implemented, add a corresponding
   `roles/bootloader/tasks/flash_emmc_<strategy>.yml`.
2. Add an entry to `roles/bootloader/vars/boards.yml` with `soc_family`,
   apt package names, capability flags, console, DTB, and target device.
3. Add host entries to `inventory/hosts.yml`.
4. Add the image URL to `armbian_image_urls` in `group_vars/all.yml`.
5. Run `populate_nfs_content.yml` — preflight will catch a wrong package
   name or a dead URL immediately.
