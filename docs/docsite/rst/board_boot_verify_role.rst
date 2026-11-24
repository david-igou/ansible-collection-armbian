.. _ansible_collections.david_igou.armbian.docsite.board_boot_verify_role:

david_igou.armbian.board_boot_verify role
=========================================

Runs on a board. Gathers the mount facts and asserts the root filesystem matches
the boot mode: NFS for ``nfs``, a non-NFS block device for ``sd``, ``local`` and
``local_kernel`` (NVMe by default), or a caller-supplied regex for custom modes.

See the :ansplugin:`full role reference <david_igou.armbian.board_boot_verify#role>`
for all parameters and defaults.
