# Migration: PR #31 (TrueNAS-container TFTP) → rb5009-hosted SBC TFTP

PR #31 deployed pxelinux.cfg + kernel/initrd/dtb under the netboot.xyz
container's TFTP root on TrueNAS, plus a RouterOS DHCP option-set
toggled on each board's lease. The 2026-05-08 redesign relocates SBC
TFTP content to rb5009's flash and drops the option-set entirely.

This document is a one-time runbook to clean up the deployed PR #31
state before running `stage_netboot_assets.yml` against the new design.

## What you're cleaning up

| Artifact | Location |
|---|---|
| RouterOS DHCP option-set objects | `armbian-nfsroot`, `armbian-tftp-server`, `armbian-nfsroot-bootfile` |
| Per-lease option-set assignment | `dhcp-option-set=armbian-nfsroot` on any board's static lease |
| TrueNAS pxelinux.cfg per-board files | `/mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/01-*` |
| TrueNAS per-model kernel/initrd/dtb | `/mnt/ssd/containers/netbootxyz/config/menus/armbian/<model>/` |

## Steps

### On rb5009 (interactive RouterOS shell)

```
/ip dhcp-server lease set [find dhcp-option-set=armbian-nfsroot] dhcp-option-set=""
/ip dhcp-server option/sets remove [find name=armbian-nfsroot]
/ip dhcp-server option remove [find name~"^armbian-"]
```

### On TrueNAS (shell with sudo)

```bash
sudo rm -rf /mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/01-*
sudo rm -rf /mnt/ssd/containers/netbootxyz/config/menus/armbian/orange-pi-5-pro/
```

## Verification

### On rb5009

```
/ip dhcp-server lease print where dhcp-option-set=armbian-nfsroot
# Expect: empty result

/ip dhcp-server option print where name~"armbian"
# Expect: empty result
```

### On TrueNAS

```bash
ls /mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/
# Expect: ENOENT or empty

ls /mnt/ssd/containers/netbootxyz/config/menus/armbian/
# Expect: ENOENT or empty (the directory itself may still exist; only the per-model subdir was removed)
```

## After migration

Run `playbooks/stage_netboot_assets.yml` to populate rb5009 from clean
state. Subsequent enable_netboot / disable_netboot cycles target rb5009
exclusively.

## Note on x86 PXE clients

This migration does not affect `igou-ansible`'s iPXE chainload path
(rb5009 → 10.10.45.242 menu.ipxe). The netboot.xyz container's TFTP
daemon is still in that chain; issue #32 (TFTP "Permission denied"
on `/config/menus/`) remains scoped to that path. SBC NFS-root and
x86 PXE menu booting are now decoupled.
