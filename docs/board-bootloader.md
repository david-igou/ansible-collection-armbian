# Board Bootloader Reference

## Supported Boards

| Board            | SoC       | SPI   | Primary Storage | DTB                                  |
|------------------|-----------|-------|-----------------|--------------------------------------|
| Orange Pi 5      | RK3588S   | Yes   | NVMe + eMMC     | rockchip/rk3588s-orangepi-5.dtb      |
| Orange Pi 5 Pro  | RK3588S   | Yes   | NVMe + eMMC     | rockchip/rk3588s-orangepi-5-pro.dtb  |
| Orange Pi 5 Max  | RK3588    | Yes   | NVMe + eMMC     | rockchip/rk3588-orangepi-5-max.dtb   |
| Rock 5B          | RK3588    | Yes*  | NVMe + eMMC     | rockchip/rk3588-rock-5b.dtb          |
| Rock 5A          | RK3588S   | No**  | NVMe + eMMC     | rockchip/rk3588s-rock-5a.dtb         |

\* Rock 5B has an SPI socket but it may ship unpopulated. Check physically before
running the bootloader playbook with `bootloader_target=spi`.

\*\* Rock 5A has no SPI. The bootloader role automatically targets eMMC boot partition.

## U-Boot Package Names (Armbian)

| Board            | Package                           |
|------------------|-----------------------------------|
| Orange Pi 5      | linux-u-boot-current-orangepi5    |
| Orange Pi 5 Pro  | linux-u-boot-current-orangepi5-pro|
| Orange Pi 5 Max  | linux-u-boot-current-orangepi5-max|
| Rock 5B          | linux-u-boot-current-rock-5b      |
| Rock 5A          | linux-u-boot-current-rock-5a      |

## Flash Targets

### SPI flash (`/dev/mtd0`)
Image: `u-boot-rockchip-spi.bin` from the installed package.
```bash
dd if=/usr/lib/linux-u-boot-current-<board>/u-boot-rockchip-spi.bin \
   of=/dev/mtd0 bs=4096 conv=notrunc
```

### eMMC boot partition (`/dev/mmcblk0boot0`)
Image: `u-boot-rockchip.bin`. The boot partition has hardware write protection
that must be toggled:
```bash
echo 0 > /sys/block/mmcblk0boot0/force_ro
dd if=/usr/lib/linux-u-boot-current-<board>/u-boot-rockchip.bin \
   of=/dev/mmcblk0boot0 bs=512
echo 1 > /sys/block/mmcblk0boot0/force_ro
```

## Verifying U-Boot PXE Support

After flashing, connect via serial and interrupt U-Boot. Check for the `pxe`
command:
```
=> help pxe
pxe - commands for PXE support
```
If `pxe` is not present the U-Boot build does not support PXE and the package
version should be updated or rebuilt with `CONFIG_CMD_PXE=y`.

## Adding a New Board

1. Add a new entry to `roles/bootloader/vars/boards.yml` with the
   correct SoC, DTB path, console, SPI availability, and Armbian package name.
2. Add host entries to `inventory/hosts.yml` with `board_model` set
   to the new key.
3. Verify the DTB path against the actual Armbian image for that board — DTB
   paths are under `/boot/dtb/rockchip/` on most Armbian builds.
4. Run `flash_bootloader.yml` and test PXE boot before adding to the server
   NFS setup.
