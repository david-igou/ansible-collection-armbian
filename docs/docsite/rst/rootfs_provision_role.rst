.. _ansible_collections.david_igou.armbian.docsite.rootfs_provision_role:

david_igou.armbian.rootfs_provision role
========================================

Runs on the netboot server. Fetches a per-host ``.img.xz`` into a source-keyed
cache, mirrors its largest partition into a per-host NFS rootfs directory with
``rsync --delete``, stages the kernel, initrd and optional DTB for TFTP, and
resets identity (hostname, machine-id, SSH host keys). A re-run is skipped while
the source, image sha256 and hostname are unchanged.

See the :ansplugin:`full role reference <david_igou.armbian.rootfs_provision#role>`
for all parameters and defaults.
