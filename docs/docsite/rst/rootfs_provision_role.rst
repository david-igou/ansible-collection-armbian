.. _ansible_collections.david_igou.armbian.docsite.rootfs_provision_role:

david_igou.armbian.rootfs_provision role
========================================

Runs on the netboot server. Fetches an Armbian image, extracts its root filesystem
into a per-host NFS directory, stages kernel, initrd and dtb for TFTP, and resets the
host identity (hostname, machine-id, SSH host keys).

See the :ansplugin:`full role reference <david_igou.armbian.rootfs_provision#role>`
for all parameters and defaults.
